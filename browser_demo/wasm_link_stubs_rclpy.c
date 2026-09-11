// Python's _ssl module (statically built into libpython3.13.a) references
// these legacy TLS 1.0/1.1/1.2-specific SSL_METHOD constructors -- absent
// from emscripten-forge-4x's openssl package (a modern build with only
// TLS_method()/generic version negotiation, no per-version legacy
// constructors). Nothing in this demo actually establishes a TLS
// connection (rmw_zenoh_pico here connects over plain ws://, not wss://),
// so these are only ever referenced by _ssl.c's static list of protocol
// constants, never called -- stub them out rather than dragging in an
// older/legacy-enabled openssl build for symbols that would always be
// "unsupported" at runtime anyway.
//
// (An earlier revision of this file stubbed rmw_get_*() graph-
// introspection functions instead -- needed when every ROS .so was
// linked directly into this executable. That's no longer the case: they
// dlopen from site-packages at runtime now, and already define these
// symbols themselves. See rclpy_boot.c's own comment.)
typedef struct ssl_method_st SSL_METHOD;

const SSL_METHOD *TLSv1_method(void) { return 0; }
const SSL_METHOD *TLSv1_1_method(void) { return 0; }
const SSL_METHOD *TLSv1_2_method(void) { return 0; }
