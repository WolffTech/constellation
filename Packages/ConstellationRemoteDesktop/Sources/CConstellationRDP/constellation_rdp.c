// FreeRDP client wrapped behind constellation_rdp.h. This owns the rdpContext,
// the client thread and every FreeRDP callback; the Swift adapter never sees a
// FreeRDP type. The render path is software GDI: FreeRDP paints into
// gdi->primary_buffer (BGRX32) and we hand that buffer and its dirty rects to
// the Swift side, which blits it into an AppKit view.

#include "constellation_rdp.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/codec/color.h>
#include <freerdp/constants.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>

#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/input.h>
#include <winpr/string.h>
#include <winpr/user.h>
#include <winpr/wlog.h>
#include <os/log.h>

#include <pthread.h>
#include <string.h>
#include <stdlib.h>

// rdpClientContext must be the first member so FreeRDP can treat this as its
// own context. `session` is the back-link to our handle.
typedef struct {
    rdpClientContext common;
    crdp_session *session;
    HANDLE stop_event;
    HANDLE command_event; // signals queued input/resolution to the client thread
} crdpContext;

// Everything that writes to the RDP transport must run on the client thread;
// the app enqueues these from the main thread and the client thread drains them.
typedef enum {
    CRDP_CMD_POINTER,
    CRDP_CMD_POINTER_EX,
    CRDP_CMD_KEY,
    CRDP_CMD_KEY_UNICODE,
    CRDP_CMD_SYNCHRONIZE,
    CRDP_CMD_RESOLUTION,
    CRDP_CMD_CLIPBOARD_TEXT,
} crdp_command_type;

typedef struct {
    crdp_command_type type;
    uint16_t flags;
    uint16_t x;
    uint16_t y;
    uint8_t scancode;
    uint16_t code;
    uint32_t a; // synchronize toggle flags, or resolution width
    uint32_t b; // resolution height
    uint32_t c; // resolution scale percent
    char *text; // owned UTF-8 for CRDP_CMD_CLIPBOARD_TEXT (NULL withdraws); freed once executed or dropped
} crdp_command;

#define CRDP_COMMAND_CAPACITY 1024

struct crdp_session {
    rdpContext *context;
    crdp_config config; // strings below are owned copies
    char *host;
    char *username;
    char *domain;
    char *password;
    crdp_callbacks callbacks;
    DispClientContext *disp; // captured when the Display Control channel connects
    // A resolution requested before the server is ready; sent once it is.
    uint32_t pending_width;
    uint32_t pending_height;
    uint32_t pending_scale;
    bool disp_ready; // Display Control caps received; layouts accepted now
    CliprdrClientContext *cliprdr; // captured when the clipboard channel connects
    bool cliprdr_ready;            // MonitorReady seen; format lists accepted now
    char *local_text;              // UTF-8 the local pasteboard offers; served on request
    volatile bool connected;
    // Tracks the buffer the Swift side last saw, so a GFX ResetGraphics realloc
    // is reported as a resize rather than an update against a stale pointer.
    const uint8_t *last_gfx_buffer;
    uint32_t last_gfx_width;
    uint32_t last_gfx_height;
    uint32_t last_gfx_stride;

    // Input/resolution command queue, drained on the client thread.
    pthread_mutex_t command_lock;
    crdp_command commands[CRDP_COMMAND_CAPACITY];
    size_t command_head;
    size_t command_count;
};

// Appends a command and wakes the client thread. Drops the oldest command if
// the queue is full (only stale pointer moves are ever lost).
static void crdp_enqueue(crdp_session *session, crdp_command command) {
    if (!session || !session->context) {
        free(command.text);
        return;
    }
    pthread_mutex_lock(&session->command_lock);
    if (session->command_count == CRDP_COMMAND_CAPACITY) {
        free(session->commands[session->command_head].text);
        session->command_head = (session->command_head + 1) % CRDP_COMMAND_CAPACITY;
        session->command_count--;
    }
    size_t tail = (session->command_head + session->command_count) % CRDP_COMMAND_CAPACITY;
    session->commands[tail] = command;
    session->command_count++;
    pthread_mutex_unlock(&session->command_lock);
    SetEvent(((crdpContext *)session->context)->command_event);
}

static bool crdp_dequeue(crdp_session *session, crdp_command *command) {
    bool ok = false;
    pthread_mutex_lock(&session->command_lock);
    if (session->command_count > 0) {
        *command = session->commands[session->command_head];
        session->command_head = (session->command_head + 1) % CRDP_COMMAND_CAPACITY;
        session->command_count--;
        ok = true;
    }
    pthread_mutex_unlock(&session->command_lock);
    return ok;
}

static wLog *crdp_log(void) {
    return WLog_Get("com.constellation.rdp");
}

static os_log_t crdp_oslog(void) {
    static os_log_t log;
    static bool created;
    if (!created) {
        log = os_log_create("tech.wolff.Constellation", "rdp");
        created = true;
    }
    return log;
}

// MS-RDPEDISP: DesktopScaleFactor is 100..500; DeviceScaleFactor is only 100,
// 140 or 180 and Windows uses it to pick icon/asset sizes.
static uint32_t crdp_desktop_scale(uint32_t percent) {
    if (percent < 100)
        return 100;
    return percent > 500 ? 500 : percent;
}

static uint32_t crdp_device_scale(uint32_t percent) {
    if (percent >= 180)
        return 180;
    return percent >= 140 ? 140 : 100;
}

static void crdp_send_layout(crdp_session *session, uint32_t width, uint32_t height,
                             uint32_t scale_percent) {
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = crdp_desktop_scale(scale_percent);
    layout.DeviceScaleFactor = crdp_device_scale(scale_percent);
    UINT rc = session->disp->SendMonitorLayout(session->disp, 1, &layout);
    WLog_Print(crdp_log(), rc == CHANNEL_RC_OK ? WLOG_DEBUG : WLOG_WARN,
               "SendMonitorLayout %" PRIu32 "x%" PRIu32 " @%" PRIu32 "%% -> %" PRIu32, width, height,
               layout.DesktopScaleFactor, rc);
}

// MARK: - Helpers

static char *dup_or_null(const char *value) {
    if (!value)
        return NULL;
    size_t length = strlen(value);
    char *copy = malloc(length + 1);
    if (copy)
        memcpy(copy, value, length + 1);
    return copy;
}

static crdp_failure map_failure(UINT32 error) {
    switch (error) {
        case FREERDP_ERROR_SUCCESS:
            return CRDP_FAILURE_NONE;
        case FREERDP_ERROR_CONNECT_CANCELLED:
            return CRDP_FAILURE_CANCELLED;
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
            return CRDP_FAILURE_AUTHENTICATION;
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
            return CRDP_FAILURE_DNS;
        case FREERDP_ERROR_TLS_CONNECT_FAILED:
        case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
            return CRDP_FAILURE_TLS;
        case FREERDP_ERROR_CONNECT_FAILED:
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
            return CRDP_FAILURE_CONNECT;
        default:
            return CRDP_FAILURE_GENERIC;
    }
}

static void emit_state(crdp_session *session, crdp_state state, crdp_failure failure) {
    if (session->callbacks.state_changed)
        session->callbacks.state_changed(session->callbacks.context, state, failure);
}

// MARK: - FreeRDP update callbacks

static BOOL crdp_end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary)
        return TRUE;

    crdp_session *session = ((crdpContext *)context)->session;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (!hwnd || !hwnd->invalid || hwnd->invalid->null)
        return TRUE;

    const HGDI_RGN invalid = hwnd->invalid;
    if (session->callbacks.frame_updated) {
        session->callbacks.frame_updated(session->callbacks.context, (uint32_t)invalid->x,
                                         (uint32_t)invalid->y, (uint32_t)invalid->w,
                                         (uint32_t)invalid->h);
    }
    return TRUE;
}

static BOOL crdp_desktop_resize(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi)
        return TRUE;

    crdp_session *session = ((crdpContext *)context)->session;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(gdi, width, height))
        return FALSE;
    os_log(crdp_oslog(), "rdp desktop_resize %ux%u", width, height);

    if (session->callbacks.frame_resized) {
        session->callbacks.frame_resized(session->callbacks.context, gdi->primary_buffer,
                                         (uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride);
    }
    return TRUE;
}

// MARK: - Graphics pipeline (RDPGFX)

// The GFX pipeline composites into gdi->primary_buffer, then calls this to
// present. gdi may have reallocated the buffer on a resize, so report a resize
// when the buffer or size changed and a plain update otherwise.
static UINT crdp_gfx_update_window(RdpgfxClientContext *gfx, gdiGfxSurface *surface) {
    (void)surface;
    rdpGdi *gdi = (rdpGdi *)gfx->custom;
    if (!gdi || !gdi->context)
        return CHANNEL_RC_OK;
    crdp_session *session = ((crdpContext *)gdi->context)->session;

    const bool changed = gdi->primary_buffer != session->last_gfx_buffer ||
                         (uint32_t)gdi->width != session->last_gfx_width ||
                         (uint32_t)gdi->height != session->last_gfx_height ||
                         gdi->stride != session->last_gfx_stride;
    if (changed) {
        session->last_gfx_buffer = gdi->primary_buffer;
        session->last_gfx_width = (uint32_t)gdi->width;
        session->last_gfx_height = (uint32_t)gdi->height;
        session->last_gfx_stride = gdi->stride;
        if (session->callbacks.frame_resized) {
            session->callbacks.frame_resized(session->callbacks.context, gdi->primary_buffer,
                                             (uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride);
        }
    } else if (session->callbacks.frame_updated) {
        session->callbacks.frame_updated(session->callbacks.context, 0, 0,
                                         (uint32_t)gdi->width, (uint32_t)gdi->height);
    }
    return CHANNEL_RC_OK;
}

// MARK: - Channel wiring

// The server sends Display Control capabilities shortly after the channel
// opens; only then will it accept a monitor layout. Send whatever was queued.
static UINT crdp_disp_caps(DispClientContext *disp, UINT32 maxNumMonitors,
                           UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB) {
    (void)maxNumMonitors;
    (void)maxMonitorAreaFactorA;
    (void)maxMonitorAreaFactorB;
    crdp_session *session = (crdp_session *)disp->custom;
    if (!session)
        return CHANNEL_RC_OK;
    session->disp_ready = true;
    if (session->pending_width && session->pending_height) {
        crdp_send_layout(session, session->pending_width, session->pending_height, session->pending_scale);
        session->pending_width = session->pending_height = session->pending_scale = 0;
    }
    return CHANNEL_RC_OK;
}

// MARK: - Clipboard (text only)
//
// Local -> remote: the Swift side hands over UTF-8 (`crdp_session_set_clipboard_text`),
// the bridge announces CF_UNICODETEXT/CF_TEXT and serves the copy when the
// server asks. Remote -> local: on a server format list with text the bridge
// requests CF_UNICODETEXT and passes the UTF-8 to the `clipboard_text` callback.
// All of it runs on the client thread, like every other transport write.

static UINT crdp_cliprdr_send_capabilities(CliprdrClientContext *cliprdr) {
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES capabilities = { 0 };
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    return cliprdr->ClientCapabilities(cliprdr, &capabilities);
}

// Announces what the local side offers: text, or nothing.
static UINT crdp_cliprdr_send_format_list(crdp_session *session) {
    CLIPRDR_FORMAT formats[2] = { { .formatId = CF_UNICODETEXT }, { .formatId = CF_TEXT } };
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = session->local_text ? 2 : 0;
    list.formats = formats;
    return session->cliprdr->ClientFormatList(session->cliprdr, &list);
}

static UINT crdp_cliprdr_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    crdp_session *session = cliprdr->custom;
    UINT rc = crdp_cliprdr_send_capabilities(cliprdr);
    if (rc != CHANNEL_RC_OK)
        return rc;
    session->cliprdr_ready = true;
    os_log(crdp_oslog(), "rdp clipboard ready, offering text=%d", session->local_text != NULL);
    return crdp_cliprdr_send_format_list(session);
}

static UINT crdp_cliprdr_server_capabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *capabilities) {
    (void)cliprdr;
    (void)capabilities;
    return CHANNEL_RC_OK; // text needs nothing beyond the base protocol
}

// The remote clipboard changed. Acknowledge, and pull the text if it has any.
static UINT crdp_cliprdr_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    bool has_text = false;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT)
            has_text = true;
    }
    os_log(crdp_oslog(), "rdp clipboard server offers %u formats, text=%d", list->numFormats, has_text);
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
    if (rc != CHANNEL_RC_OK || !has_text)
        return rc;
    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = CF_UNICODETEXT;
    return cliprdr->ClientFormatDataRequest(cliprdr, &request);
}

static UINT crdp_cliprdr_server_format_list_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)cliprdr;
    (void)response;
    return CHANNEL_RC_OK;
}

// The server wants the text we announced.
static UINT crdp_cliprdr_server_format_data_request(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    crdp_session *session = cliprdr->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    WCHAR *wide = NULL;
    if (session->local_text && request->requestedFormatId == CF_UNICODETEXT) {
        size_t length = 0;
        wide = ConvertUtf8ToWCharAlloc(session->local_text, &length);
        if (wide) {
            response.common.msgFlags = CB_RESPONSE_OK;
            response.common.dataLen = (UINT32)((length + 1) * sizeof(WCHAR)); // with terminator
            response.requestedFormatData = (const BYTE *)wide;
        }
    } else if (session->local_text && request->requestedFormatId == CF_TEXT) {
        // CF_TEXT is in the server's ANSI code page; UTF-8 is the closest we
        // have and matches for ASCII, which is what this format is used for.
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)(strlen(session->local_text) + 1);
        response.requestedFormatData = (const BYTE *)session->local_text;
    }
    // Length only; clipboard contents never reach the log.
    os_log(crdp_oslog(), "rdp clipboard server requested format %u -> %s (%u bytes)",
           request->requestedFormatId, response.common.msgFlags == CB_RESPONSE_OK ? "ok" : "fail",
           response.common.dataLen);
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(wide);
    return rc;
}

// The text we asked for after a server format list.
static UINT crdp_cliprdr_server_format_data_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    crdp_session *session = cliprdr->custom;
    if (!(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData ||
        !session->callbacks.clipboard_text)
        return CHANNEL_RC_OK;
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData,
                                          response->common.dataLen / sizeof(WCHAR), NULL);
    if (!utf8)
        return CHANNEL_RC_OK;
    os_log(crdp_oslog(), "rdp clipboard received text (%u bytes)", response->common.dataLen);
    session->callbacks.clipboard_text(session->callbacks.context, utf8);
    free(utf8);
    return CHANNEL_RC_OK;
}

// Runs on the client thread: takes ownership of `text` and re-announces.
static void crdp_apply_clipboard_text(crdp_session *session, char *text) {
    free(session->local_text);
    session->local_text = text;
    if (session->cliprdr && session->cliprdr_ready && session->local_text)
        crdp_cliprdr_send_format_list(session);
}

static void crdp_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    crdp_session *session = ((crdpContext *)context)->session;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        session->disp = (DispClientContext *)e->pInterface;
        session->disp->custom = session;
        session->disp->DisplayControlCaps = crdp_disp_caps;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *cliprdr = (CliprdrClientContext *)e->pInterface;
        cliprdr->custom = session;
        cliprdr->MonitorReady = crdp_cliprdr_monitor_ready;
        cliprdr->ServerCapabilities = crdp_cliprdr_server_capabilities;
        cliprdr->ServerFormatList = crdp_cliprdr_server_format_list;
        cliprdr->ServerFormatListResponse = crdp_cliprdr_server_format_list_response;
        cliprdr->ServerFormatDataRequest = crdp_cliprdr_server_format_data_request;
        cliprdr->ServerFormatDataResponse = crdp_cliprdr_server_format_data_response;
        session->cliprdr = cliprdr;
    }
    freerdp_client_OnChannelConnectedEventHandler(context, e);

    // The default handler above initializes gdi's GFX pipeline; route its
    // presentation callback to us so GFX frames reach the view.
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        gfx->UpdateWindowFromSurface = crdp_gfx_update_window;
    }
}

static void crdp_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    crdp_session *session = ((crdpContext *)context)->session;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        session->disp = NULL;
        session->disp_ready = false;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        session->cliprdr = NULL;
        session->cliprdr_ready = false;
    }
    freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

// MARK: - Connection lifecycle callbacks

static BOOL crdp_pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *settings = context->settings;

    rdpUpdate *update = context->update;
    update->EndPaint = crdp_end_paint;
    update->DesktopResize = crdp_desktop_resize;

    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH))
        return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
        return FALSE;

    PubSub_SubscribeChannelConnected(context->pubSub, crdp_on_channel_connected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, crdp_on_channel_disconnected);
    return TRUE;
}

static BOOL crdp_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
        return FALSE;

    rdpContext *context = instance->context;
    rdpGdi *gdi = context->gdi;
    crdp_session *session = ((crdpContext *)context)->session;
    rdpSettings *settings = context->settings;
    os_log(crdp_oslog(),
           "rdp post_connect %ux%u depth=%u rfx=%d gfx=%d nsc=%d autodetect=%d",
           (uint32_t)gdi->width, (uint32_t)gdi->height,
           freerdp_settings_get_uint32(settings, FreeRDP_ColorDepth),
           freerdp_settings_get_bool(settings, FreeRDP_RemoteFxCodec),
           freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline),
           freerdp_settings_get_bool(settings, FreeRDP_NSCodec),
           freerdp_settings_get_bool(settings, FreeRDP_NetworkAutoDetect));
    if (session->callbacks.frame_resized) {
        session->callbacks.frame_resized(session->callbacks.context, gdi->primary_buffer,
                                         (uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride);
    }
    return TRUE;
}

static void crdp_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context)
        return;
    gdi_free(instance);
}

// Credentials are supplied up front through settings. FreeRDP only calls this
// when they are missing or were rejected, so aborting here surfaces as an
// authentication failure rather than looping.
static BOOL crdp_authenticate_ex(freerdp *instance, char **username, char **password,
                                 char **domain, rdp_auth_reason reason) {
    (void)instance;
    (void)username;
    (void)password;
    (void)domain;
    (void)reason;
    return FALSE;
}

static crdp_cert_verdict crdp_ask_certificate(freerdp *instance, const char *host, UINT16 port,
                                              const char *common_name, const char *subject,
                                              const char *issuer, const char *fingerprint,
                                              BOOL changed, DWORD flags) {
    crdp_session *session = ((crdpContext *)instance->context)->session;
    if (!session->callbacks.verify_certificate)
        return CRDP_CERT_REJECT;

    crdp_certificate certificate = {
        .host = host,
        .port = port,
        .common_name = common_name,
        .subject = subject,
        .issuer = issuer,
        .fingerprint = fingerprint,
        .host_mismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0,
        .changed = changed || (flags & VERIFY_CERT_FLAG_CHANGED) != 0,
    };
    return session->callbacks.verify_certificate(session->callbacks.context, &certificate);
}

static DWORD crdp_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                        const char *common_name, const char *subject,
                                        const char *issuer, const char *fingerprint, DWORD flags) {
    return (DWORD)crdp_ask_certificate(instance, host, port, common_name, subject, issuer,
                                       fingerprint, FALSE, flags);
}

static DWORD crdp_verify_changed_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                                const char *common_name, const char *subject,
                                                const char *issuer, const char *new_fingerprint,
                                                const char *old_subject, const char *old_issuer,
                                                const char *old_fingerprint, DWORD flags) {
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    return (DWORD)crdp_ask_certificate(instance, host, port, common_name, subject, issuer,
                                       new_fingerprint, TRUE, flags);
}

// MARK: - Command execution (client thread only)

// Runs a resolution request now that we are on the client thread. Holds it
// until the server's Display Control caps arrive.
static void crdp_apply_resolution(crdp_session *session, uint32_t width, uint32_t height,
                                  uint32_t scale_percent) {
    if (!session->connected || !session->config.dynamic_resolution)
        return;
    width &= ~1u; // MS-RDPEDISP: even width, 200..8192 per side
    if (width < 200 || height < 200 || width > 8192 || height > 8192)
        return;
    if (!session->disp || !session->disp->SendMonitorLayout || !session->disp_ready) {
        session->pending_width = width;
        session->pending_height = height;
        session->pending_scale = scale_percent;
        return;
    }
    crdp_send_layout(session, width, height, scale_percent);
}

static void crdp_execute(crdp_session *session, const crdp_command *command) {
    rdpInput *input = session->context->input;
    switch (command->type) {
        case CRDP_CMD_POINTER:
            freerdp_input_send_mouse_event(input, command->flags, command->x, command->y);
            break;
        case CRDP_CMD_POINTER_EX:
            freerdp_input_send_extended_mouse_event(input, command->flags, command->x, command->y);
            break;
        case CRDP_CMD_KEY:
            freerdp_input_send_keyboard_event(input, command->flags, command->scancode);
            break;
        case CRDP_CMD_KEY_UNICODE:
            freerdp_input_send_unicode_keyboard_event(input, command->flags, command->code);
            break;
        case CRDP_CMD_SYNCHRONIZE:
            freerdp_input_send_synchronize_event(input, command->a);
            break;
        case CRDP_CMD_RESOLUTION:
            crdp_apply_resolution(session, command->a, command->b, command->c);
            break;
        case CRDP_CMD_CLIPBOARD_TEXT:
            crdp_apply_clipboard_text(session, command->text);
            break;
    }
}

static void crdp_drain_commands(crdp_session *session) {
    crdp_command command;
    while (session->connected && crdp_dequeue(session, &command))
        crdp_execute(session, &command);
}

// MARK: - Client thread

static DWORD WINAPI crdp_client_thread(LPVOID param) {
    rdpContext *context = (rdpContext *)param;
    crdpContext *cctx = (crdpContext *)param;
    crdp_session *session = cctx->session;
    freerdp *instance = context->instance;

    if (!freerdp_connect(instance)) {
        crdp_failure failure = map_failure(freerdp_get_last_error(context));
        emit_state(session, CRDP_STATE_DISCONNECTED,
                   failure == CRDP_FAILURE_NONE ? CRDP_FAILURE_GENERIC : failure);
        return 0;
    }

    session->connected = true;
    emit_state(session, CRDP_STATE_CONNECTED, CRDP_FAILURE_NONE);

    // Send anything queued before the loop started waiting.
    crdp_drain_commands(session);

    HANDLE handles[64];
    while (!freerdp_shall_disconnect_context(context)) {
        DWORD count = 0;
        handles[count++] = cctx->stop_event;
        handles[count++] = cctx->command_event;

        DWORD extra = freerdp_get_event_handles(context, &handles[count], 64 - count);
        if (extra == 0)
            break;
        count += extra;

        DWORD wait = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0) // stop requested
            break;
        if (wait == WAIT_FAILED)
            break;

        // Input and resolution changes are queued from the main thread; run
        // them here so the transport is only ever touched by this thread.
        crdp_drain_commands(session);

        if (!freerdp_check_event_handles(context))
            break;
    }

    const UINT32 error = freerdp_get_last_error(context);
    session->connected = false;
    freerdp_disconnect(instance);
    emit_state(session, CRDP_STATE_DISCONNECTED, map_failure(error));
    return 0;
}

// MARK: - Entry points

static BOOL crdp_client_new(freerdp *instance, rdpContext *context) {
    crdpContext *cctx = (crdpContext *)context;
    instance->PreConnect = crdp_pre_connect;
    instance->PostConnect = crdp_post_connect;
    instance->PostDisconnect = crdp_post_disconnect;
    instance->AuthenticateEx = crdp_authenticate_ex;
    instance->VerifyCertificateEx = crdp_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = crdp_verify_changed_certificate_ex;

    cctx->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    cctx->command_event = CreateEvent(NULL, FALSE, FALSE, NULL);
    return cctx->stop_event != NULL && cctx->command_event != NULL;
}

static void crdp_client_free(freerdp *instance, rdpContext *context) {
    (void)instance;
    crdpContext *cctx = (crdpContext *)context;
    if (cctx->stop_event) {
        CloseHandle(cctx->stop_event);
        cctx->stop_event = NULL;
    }
    if (cctx->command_event) {
        CloseHandle(cctx->command_event);
        cctx->command_event = NULL;
    }
}

static int crdp_client_start(rdpContext *context) {
    crdpContext *cctx = (crdpContext *)context;
    cctx->common.thread = CreateThread(NULL, 0, crdp_client_thread, context, 0, NULL);
    return cctx->common.thread ? 0 : -1;
}

static int crdp_client_stop(rdpContext *context) {
    return freerdp_client_common_stop(context);
}

// MARK: - Public API

crdp_session *crdp_session_create(const crdp_config *config, const crdp_callbacks *callbacks) {
    crdp_session *session = calloc(1, sizeof(*session));
    if (!session)
        return NULL;

    session->config = *config;
    session->callbacks = *callbacks;
    pthread_mutex_init(&session->command_lock, NULL);
    session->host = dup_or_null(config->host);
    session->username = dup_or_null(config->username);
    session->domain = dup_or_null(config->domain);
    session->password = dup_or_null(config->password);

    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Size = sizeof(entry);
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.ContextSize = sizeof(crdpContext);
    entry.ClientNew = crdp_client_new;
    entry.ClientFree = crdp_client_free;
    entry.ClientStart = crdp_client_start;
    entry.ClientStop = crdp_client_stop;

    rdpContext *context = freerdp_client_context_new(&entry);
    if (!context) {
        crdp_session_free(session);
        return NULL;
    }
    ((crdpContext *)context)->session = session;
    session->context = context;

    rdpSettings *settings = context->settings;
    freerdp_settings_set_string(settings, FreeRDP_ServerHostname, session->host);
    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config->port ? config->port : 3389);
    if (session->username)
        freerdp_settings_set_string(settings, FreeRDP_Username, session->username);
    if (session->domain)
        freerdp_settings_set_string(settings, FreeRDP_Domain, session->domain);
    if (session->password) {
        freerdp_settings_set_string(settings, FreeRDP_Password, session->password);
        freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, TRUE);
    }
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, config->width);
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, config->height);
    // The scale rides along in the initial monitor data so a Retina session
    // logs in with a 200% desktop rather than resizing after the first frame.
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, crdp_desktop_scale(config->scale_percent));
    freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, crdp_device_scale(config->scale_percent));
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);

    // Software GDI composites everything (legacy bitmaps, RemoteFX and the GFX
    // pipeline) into primary_buffer. Modern Windows drives the screen through
    // the Graphics Pipeline, so it must be on or the desktop freezes after the
    // first frame. H.264 stays out (no decoder is built), so the server uses
    // RemoteFX Progressive over GFX, which FreeRDP decodes itself.
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE);

    // Channel loading is driven by these flags; anything the build script left
    // out (audio, video, remote assistance, RemoteApp, WebAuthn, credential
    // guard, ssh-agent) must be off or pre_connect fails to load its addin.
    freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportVideoOptimized, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGeometryTracking, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportEchoChannel, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportSSHAgentChannel, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteCredentialGuard, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectWebAuthN, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_MultiTouchInput, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_EncomspVirtualChannel, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemdeskVirtualChannel, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, FALSE);

    freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, config->share_clipboard);
    freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, config->dynamic_resolution);
    freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, config->dynamic_resolution);

    return session;
}

void crdp_session_connect(crdp_session *session) {
    if (!session || !session->context)
        return;
    emit_state(session, CRDP_STATE_CONNECTING, CRDP_FAILURE_NONE);
    freerdp_client_start(session->context);
}

void crdp_session_disconnect(crdp_session *session) {
    if (!session || !session->context)
        return;
    crdpContext *cctx = (crdpContext *)session->context;
    freerdp_abort_connect_context(session->context);
    if (cctx->stop_event)
        SetEvent(cctx->stop_event);
}

void crdp_session_free(crdp_session *session) {
    if (!session)
        return;
    if (session->context) {
        crdp_session_disconnect(session);
        freerdp_client_stop(session->context); // joins the client thread
        freerdp_client_context_free(session->context);
        session->context = NULL;
    }
    free(session->host);
    free(session->username);
    if (session->password) {
        // The password lived here only until it reached settings; wipe the copy.
        memset(session->password, 0, strlen(session->password));
        free(session->password);
    }
    free(session->domain);
    free(session->local_text);
    crdp_command leftover;
    while (crdp_dequeue(session, &leftover))
        free(leftover.text);
    pthread_mutex_destroy(&session->command_lock);
    free(session);
}

// MARK: - Input

void crdp_session_send_pointer(crdp_session *session, uint16_t flags, uint16_t x, uint16_t y) {
    if (!session || !session->connected)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_POINTER, .flags = flags, .x = x, .y = y });
}

void crdp_session_send_pointer_extended(crdp_session *session, uint16_t flags, uint16_t x,
                                        uint16_t y) {
    if (!session || !session->connected)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_POINTER_EX, .flags = flags, .x = x, .y = y });
}

void crdp_session_send_key(crdp_session *session, uint16_t flags, uint8_t scancode) {
    if (!session || !session->connected)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_KEY, .flags = flags, .scancode = scancode });
}

void crdp_session_send_key_unicode(crdp_session *session, uint16_t flags, uint16_t code) {
    if (!session || !session->connected)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_KEY_UNICODE, .flags = flags, .code = code });
}

void crdp_session_send_synchronize(crdp_session *session, uint32_t toggle_flags) {
    if (!session || !session->connected)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_SYNCHRONIZE, .a = toggle_flags });
}

void crdp_session_request_resolution(crdp_session *session, uint32_t width, uint32_t height,
                                     uint32_t scale_percent) {
    if (!session || !session->connected || !session->config.dynamic_resolution)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_RESOLUTION, .a = width, .b = height, .c = scale_percent });
}

void crdp_session_set_clipboard_text(crdp_session *session, const char *utf8) {
    if (!session || !session->connected || !session->config.share_clipboard)
        return;
    char *copy = utf8 ? strdup(utf8) : NULL;
    if (utf8 && !copy)
        return;
    crdp_enqueue(session, (crdp_command){ .type = CRDP_CMD_CLIPBOARD_TEXT, .text = copy });
}

uint8_t crdp_scancode_for_mac_keycode(uint16_t mac_keycode, bool *extended) {
    DWORD vkcode = GetVirtualKeyCodeFromKeycode(mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, WINPR_KBD_TYPE_IBM_ENHANCED);
    if (extended)
        *extended = (scancode & KBDEXT) != 0;
    return (uint8_t)(scancode & 0xFF);
}
