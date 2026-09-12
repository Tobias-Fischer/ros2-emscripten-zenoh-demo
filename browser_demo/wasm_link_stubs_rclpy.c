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

// rmw_zenoh_pico doesn't implement the service/client introspection half of
// the rmw API (rmw_get_clients_info_by_service and friends -- confirmed via
// `nm` against librmw_zenoh_pico.so: only the topic-side
// rmw_get_publishers_info_by_topic/rmw_get_subscriptions_info_by_topic
// exist). rclpy's own pybind11 module (_rclpy_pybind11.so) still references
// them unconditionally (it wraps the full rmw API surface, not just what a
// given rmw implementation supports), so the dlopen'd side module aborts
// with an "undefined symbol" assertion unless something defines them.
// Stubbed here (compiled into the MAIN_MODULE, exported via
// EXPORTED_FUNCTIONS in build_rclpy.sh) rather than in rmw_zenoh_pico
// itself -- this demo never calls the service-introspection rclpy APIs
// (talker_rclpy.py only publishes), so a RMW_RET_UNSUPPORTED stub is
// sufficient; a real fix belongs further upstream in rmw_zenoh_pico.
#include "rmw/rmw.h"
#include "rmw/get_service_endpoint_info.h"
#include "rmw/get_topic_endpoint_info.h"
#include "rmw/names_and_types.h"

rmw_ret_t rmw_get_clients_info_by_service(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *service_name, bool no_mangle,
    rmw_service_endpoint_info_array_t *clients_info) {
  (void)node; (void)allocator; (void)service_name; (void)no_mangle; (void)clients_info;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_servers_info_by_service(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *service_name, bool no_mangle,
    rmw_service_endpoint_info_array_t *servers_info) {
  (void)node; (void)allocator; (void)service_name; (void)no_mangle; (void)servers_info;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_service_names_and_types(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    rmw_names_and_types_t *service_names_and_types) {
  (void)node; (void)allocator; (void)service_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_service_names_and_types_by_node(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *node_name, const char *node_namespace,
    rmw_names_and_types_t *service_names_and_types) {
  (void)node; (void)allocator; (void)node_name; (void)node_namespace; (void)service_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_client_names_and_types_by_node(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *node_name, const char *node_namespace,
    rmw_names_and_types_t *service_names_and_types) {
  (void)node; (void)allocator; (void)node_name; (void)node_namespace; (void)service_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_publisher_names_and_types_by_node(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *node_name, const char *node_namespace, bool no_demangle,
    rmw_names_and_types_t *topic_names_and_types) {
  (void)node; (void)allocator; (void)node_name; (void)node_namespace; (void)no_demangle; (void)topic_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_subscriber_names_and_types_by_node(
    const rmw_node_t *node, rcutils_allocator_t *allocator,
    const char *node_name, const char *node_namespace, bool no_demangle,
    rmw_names_and_types_t *topic_names_and_types) {
  (void)node; (void)allocator; (void)node_name; (void)node_namespace; (void)no_demangle; (void)topic_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

rmw_ret_t rmw_get_topic_names_and_types(
    const rmw_node_t *node, rcutils_allocator_t *allocator, bool no_demangle,
    rmw_names_and_types_t *topic_names_and_types) {
  (void)node; (void)allocator; (void)no_demangle; (void)topic_names_and_types;
  return RMW_RET_UNSUPPORTED;
}

const char *rmw_get_implementation_identifier(void) {
  return "rmw_zenoh_pico";
}

const char *rmw_get_serialization_format(void) {
  return "cdr";
}
