// C bridge over FreeRDP. Every pointer FreeRDP owns and every C callback lives
// behind this interface; the Swift adapter sees an opaque session, an owned
// BGRA frame buffer and typed callbacks. Callbacks fire on FreeRDP's client
// thread — the Swift side hops to the main actor before touching UI.
#ifndef CONSTELLATION_RDP_H
#define CONSTELLATION_RDP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct crdp_session crdp_session;

typedef enum {
    CRDP_STATE_IDLE = 0,
    CRDP_STATE_CONNECTING,
    CRDP_STATE_CONNECTED,
    CRDP_STATE_DISCONNECTED,
} crdp_state;

/// Why a session ended. `CRDP_FAILURE_NONE` is a clean local or server close.
typedef enum {
    CRDP_FAILURE_NONE = 0,
    CRDP_FAILURE_GENERIC,
    CRDP_FAILURE_AUTHENTICATION, // logon failure, wrong password, access denied
    CRDP_FAILURE_CANCELLED,      // user aborted (e.g. rejected a certificate)
    CRDP_FAILURE_DNS,
    CRDP_FAILURE_TLS,
    CRDP_FAILURE_CONNECT,        // TCP connect / transport failed
} crdp_failure;

/// Certificate verdicts, matching FreeRDP's VerifyCertificateEx return values.
typedef enum {
    CRDP_CERT_REJECT = 0,
    CRDP_CERT_ACCEPT_AND_STORE = 1,
    CRDP_CERT_ACCEPT_ONCE = 2,
} crdp_cert_verdict;

typedef struct {
    const char *host;
    uint32_t port; // 0 means the RDP default, 3389
    const char *username; // may be NULL
    const char *domain;   // may be NULL
    const char *password; // may be NULL; copied into settings, not retained here
    uint32_t width;
    uint32_t height;
    bool dynamic_resolution; // negotiate the Display Control channel
    bool share_clipboard;
} crdp_config;

/// A certificate awaiting a verdict. Pointers are valid only for the duration
/// of the `verify_certificate` call.
typedef struct {
    const char *host;
    uint32_t port;
    const char *common_name;
    const char *subject;
    const char *issuer;
    const char *fingerprint;
    bool host_mismatch;
    bool changed; // the stored certificate differs from this one
} crdp_certificate;

/// FreeRDP calls these from the client thread. `context` is the opaque pointer
/// passed to `crdp_session_create`.
typedef struct {
    void *context;
    void (*state_changed)(void *context, crdp_state state, crdp_failure failure);
    /// The frame buffer was (re)allocated. `buffer` is `height * stride` bytes
    /// of BGRA (alpha ignored); it stays valid until the next resize or free.
    void (*frame_resized)(void *context, const uint8_t *buffer, uint32_t width,
                          uint32_t height, uint32_t stride);
    /// A rectangle of the current buffer changed.
    void (*frame_updated)(void *context, uint32_t x, uint32_t y, uint32_t width,
                          uint32_t height);
    /// Blocks the client thread until the user decides. Returning a verdict
    /// lets connection setup continue; `CRDP_CERT_REJECT` aborts it.
    crdp_cert_verdict (*verify_certificate)(void *context,
                                            const crdp_certificate *certificate);
} crdp_callbacks;

/// Builds a session. Copies `config` and `callbacks`; both may be freed after.
/// Returns NULL only on allocation failure.
crdp_session *crdp_session_create(const crdp_config *config,
                                  const crdp_callbacks *callbacks);

/// Spawns the client thread and starts connecting. State changes arrive on the
/// `state_changed` callback.
void crdp_session_connect(crdp_session *session);

/// Asks the client thread to disconnect. Returns immediately; the terminal
/// state arrives on `state_changed`.
void crdp_session_disconnect(crdp_session *session);

/// Joins the client thread and frees everything. Safe to call once, after
/// which `session` is invalid.
void crdp_session_free(crdp_session *session);

// Input. `flags` use FreeRDP's PTR_FLAGS_* / KBD_FLAGS_* values; the Swift
// adapter owns the NSEvent translation and passes them through.
void crdp_session_send_pointer(crdp_session *session, uint16_t flags, uint16_t x,
                               uint16_t y);
void crdp_session_send_pointer_extended(crdp_session *session, uint16_t flags,
                                        uint16_t x, uint16_t y);
void crdp_session_send_key(crdp_session *session, uint16_t flags, uint8_t scancode);
void crdp_session_send_key_unicode(crdp_session *session, uint16_t flags,
                                   uint16_t code);
/// Resends the lock-key state (caps/num/scroll) after a focus change.
void crdp_session_send_synchronize(crdp_session *session, uint32_t toggle_flags);

/// Requests a new desktop resolution over the Display Control channel. A no-op
/// unless the session negotiated `dynamic_resolution` and is connected.
void crdp_session_request_resolution(crdp_session *session, uint32_t width,
                                     uint32_t height);

/// Translates a macOS virtual key code (NSEvent.keyCode) to an RDP scancode,
/// returning the KBD_FLAGS_EXTENDED bit in `*extended`. Returns 0 if unmapped.
uint8_t crdp_scancode_for_mac_keycode(uint16_t mac_keycode, bool *extended);

#ifdef __cplusplus
}
#endif

#endif // CONSTELLATION_RDP_H
