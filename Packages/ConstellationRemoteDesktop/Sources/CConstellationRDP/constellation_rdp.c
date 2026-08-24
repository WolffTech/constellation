// FreeRDP client wrapped behind constellation_rdp.h. This owns the rdpContext,
// the client thread and every FreeRDP callback; the Swift adapter never sees a
// FreeRDP type. The render path is software GDI: FreeRDP paints into
// gdi->primary_buffer (BGRX32) and we hand that buffer and its dirty rects to
// the Swift side, which blits it into an AppKit view.

#include "constellation_rdp.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
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

#include <string.h>
#include <stdlib.h>

// rdpClientContext must be the first member so FreeRDP can treat this as its
// own context. `session` is the back-link to our handle.
typedef struct {
    rdpClientContext common;
    crdp_session *session;
    HANDLE stop_event;
} crdpContext;

struct crdp_session {
    rdpContext *context;
    crdp_config config; // strings below are owned copies
    char *host;
    char *username;
    char *domain;
    char *password;
    crdp_callbacks callbacks;
    DispClientContext *disp; // captured when the Display Control channel connects
    volatile bool connected;
};

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

    if (session->callbacks.frame_resized) {
        session->callbacks.frame_resized(session->callbacks.context, gdi->primary_buffer,
                                         (uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride);
    }
    return TRUE;
}

// MARK: - Channel wiring

static void crdp_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    crdp_session *session = ((crdpContext *)context)->session;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        session->disp = (DispClientContext *)e->pInterface;
    freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void crdp_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    crdp_session *session = ((crdpContext *)context)->session;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        session->disp = NULL;
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

    HANDLE handles[64];
    while (!freerdp_shall_disconnect_context(context)) {
        DWORD count = 0;
        handles[count++] = cctx->stop_event;

        DWORD extra = freerdp_get_event_handles(context, &handles[count], 64 - count);
        if (extra == 0)
            break;
        count += extra;

        DWORD wait = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0) // stop requested
            break;
        if (wait == WAIT_FAILED)
            break;

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
    return cctx->stop_event != NULL;
}

static void crdp_client_free(freerdp *instance, rdpContext *context) {
    (void)instance;
    crdpContext *cctx = (crdpContext *)context;
    if (cctx->stop_event) {
        CloseHandle(cctx->stop_event);
        cctx->stop_event = NULL;
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
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);

    // Software GDI paints into primary_buffer; the graphics pipeline would
    // bypass it. The proof renders the plain bitmap path.
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, FALSE);

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
    free(session);
}

// MARK: - Input

void crdp_session_send_pointer(crdp_session *session, uint16_t flags, uint16_t x, uint16_t y) {
    if (!session || !session->connected)
        return;
    freerdp_input_send_mouse_event(session->context->input, flags, x, y);
}

void crdp_session_send_pointer_extended(crdp_session *session, uint16_t flags, uint16_t x,
                                        uint16_t y) {
    if (!session || !session->connected)
        return;
    freerdp_input_send_extended_mouse_event(session->context->input, flags, x, y);
}

void crdp_session_send_key(crdp_session *session, uint16_t flags, uint8_t scancode) {
    if (!session || !session->connected)
        return;
    freerdp_input_send_keyboard_event(session->context->input, flags, scancode);
}

void crdp_session_send_key_unicode(crdp_session *session, uint16_t flags, uint16_t code) {
    if (!session || !session->connected)
        return;
    freerdp_input_send_unicode_keyboard_event(session->context->input, flags, code);
}

void crdp_session_send_synchronize(crdp_session *session, uint32_t toggle_flags) {
    if (!session || !session->connected)
        return;
    freerdp_input_send_synchronize_event(session->context->input, toggle_flags);
}

void crdp_session_request_resolution(crdp_session *session, uint32_t width, uint32_t height) {
    if (!session || !session->connected || !session->disp || !session->disp->SendMonitorLayout)
        return;

    freerdp_settings_set_uint32(session->context->settings, FreeRDP_DesktopWidth, width);
    freerdp_settings_set_uint32(session->context->settings, FreeRDP_DesktopHeight, height);

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;
    session->disp->SendMonitorLayout(session->disp, 1, &layout);
}

uint8_t crdp_scancode_for_mac_keycode(uint16_t mac_keycode, bool *extended) {
    DWORD vkcode = GetVirtualKeyCodeFromKeycode(mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, WINPR_KBD_TYPE_IBM_ENHANCED);
    if (extended)
        *extended = (scancode & KBDEXT) != 0;
    return (uint8_t)(scancode & 0xFF);
}
