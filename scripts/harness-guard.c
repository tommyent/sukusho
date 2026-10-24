// Loaded into windowless harnesses that host app views (DYLD_INSERT_LIBRARIES).
// Any keychain or permission call ends the process before it reaches the
// keychain, so a hosted view that touches one can never prompt the user or
// read a credential (2026-10-09: two keychain prompts from an unguarded run).
// Exit status 7 means the view touched one and must be reviewed from source.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <Security/Security.h>
#include <stdio.h>
#include <unistd.h>

#define DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *a; const void *b; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };

static void blocked(const char *call) {
    fprintf(stderr, "GUARD: blocked %s: this view touches the keychain or a permission API\n", call);
    fflush(stderr);
    _exit(7);
}

static OSStatus g_copy(CFDictionaryRef q, CFTypeRef *r) { blocked("SecItemCopyMatching"); return errSecInteractionNotAllowed; }
static OSStatus g_add(CFDictionaryRef a, CFTypeRef *r) { blocked("SecItemAdd"); return errSecInteractionNotAllowed; }
static OSStatus g_update(CFDictionaryRef q, CFDictionaryRef a) { blocked("SecItemUpdate"); return errSecInteractionNotAllowed; }
static OSStatus g_delete(CFDictionaryRef q) { blocked("SecItemDelete"); return errSecInteractionNotAllowed; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus g_find(CFTypeRef k, UInt32 sl, const char *s, UInt32 al, const char *a, UInt32 *pl, void **pd, SecKeychainItemRef *i) {
    blocked("SecKeychainFindGenericPassword"); return errSecInteractionNotAllowed;
}
DYLD_INTERPOSE(g_find, SecKeychainFindGenericPassword)
#pragma clang diagnostic pop
static bool g_request(void) { blocked("CGRequestScreenCaptureAccess"); return false; }
static bool g_preflight(void) { blocked("CGPreflightScreenCaptureAccess"); return false; }
static Boolean g_trusted(CFDictionaryRef o) { blocked("AXIsProcessTrustedWithOptions"); return false; }

DYLD_INTERPOSE(g_copy, SecItemCopyMatching)
DYLD_INTERPOSE(g_add, SecItemAdd)
DYLD_INTERPOSE(g_update, SecItemUpdate)
DYLD_INTERPOSE(g_delete, SecItemDelete)
DYLD_INTERPOSE(g_request, CGRequestScreenCaptureAccess)
DYLD_INTERPOSE(g_preflight, CGPreflightScreenCaptureAccess)
DYLD_INTERPOSE(g_trusted, AXIsProcessTrustedWithOptions)
