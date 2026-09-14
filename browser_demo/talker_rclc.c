#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <emscripten.h>

#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
// Not <rmw_zenoh_pico/rmw_zenoh_pico.h> -- its own transitive includes pull
// in rosidl_typesupport_microxrcedds_c's <ucdr/microcdr.h>, which isn't on
// this demo's (deliberately minimal) include path. config.h + options.h is
// all rmw_zenoh_pico_set_unicast()'s declaration actually needs: config.h
// defines RMW_ZENOH_PICO_TRANSPORT_UNICAST, which options.h's declaration
// is guarded on.
#include <rmw_zenoh_pico/config.h>
#include <rmw_zenoh_pico/rmw_zenoh_pico_options.h>
#include <std_msgs/msg/string.h>
#include <rosidl_runtime_c/string_functions.h>

// The zenoh connect address rmw_zenoh_pico compiles in (127.0.0.1:7447) is
// only a *default* -- rmw_zenoh_pico_set_unicast() overrides it at runtime,
// but has to run before rclc_support_init() opens the session. main() is
// linked with -sINVOKE_RUN=0 so JS can write into this buffer (still empty
// means "use the compiled-in default") before calling Module.callMain()
// itself -- see index_rclc.html.
#define ZENOH_HOST_MAX 64
#define ZENOH_PORT_MAX 8
static char zenoh_connect_host[ZENOH_HOST_MAX] = "";
static char zenoh_connect_port[ZENOH_PORT_MAX] = "";

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_host_buf(void) { return zenoh_connect_host; }

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_port_buf(void) { return zenoh_connect_port; }

// RCL_RET_PUBLISHER_INVALID (300) is what every rcl_publish() call
// returns, over and over, whenever the wasm32 build can't reach a zenoh
// router at ws://127.0.0.1:7447 -- expected while none is running yet,
// not a crash, but "Failed status on line N: 300" reads like one, so
// spell out what it actually means instead of just the raw code.
#define RCCHECK(fn) { rcl_ret_t rc = fn; if (rc != RCL_RET_OK) { \
  if (rc == RCL_RET_PUBLISHER_INVALID) { \
    printf("Line %d: publisher invalid (rc=%d) -- usually means no zenoh router is reachable yet at ws://%s:%s; start one (see the site's setup box).\n", __LINE__, (int)rc, \
      zenoh_connect_host[0] != '\0' ? zenoh_connect_host : "127.0.0.1", \
      zenoh_connect_port[0] != '\0' ? zenoh_connect_port : "7447"); \
  } else { \
    printf("Failed status on line %d: %d\n", __LINE__, (int)rc); \
  } } }

rcl_publisher_t publisher;
std_msgs__msg__String msg;
size_t counter = 0;

// Survive past main() returning -- see rclc_demo_spin_once() below. This
// project's rcl/rmw/zenoh-pico stack dropped pthreads+Asyncify project-wide
// (rmw_zenoh_pico's rmw_wait() now polls zenoh-pico's non-threaded
// zp_read()/zp_send_keep_alive() API directly instead of blocking on a
// condvar another thread would signal), so there is no longer anything for
// a blocking `while (true) { rclc_executor_spin_some(...); }` loop in
// main() to cooperatively yield *from* -- Asyncify only mattered when that
// loop had to suspend/resume around a real blocking wait. main() now just
// does one-time setup and returns; index_rclc.html drives repeated spins
// from JS instead (a setInterval calling rclc_demo_spin_once()).
static rclc_support_t support;
static rcl_node_t node;
static rclc_executor_t executor;
static rcl_timer_t timer;

void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  char buf[128];
  snprintf(buf, sizeof(buf), "Hello from wasm32 rclc (rmw_zenoh_pico) #%zu", counter++);
  rosidl_runtime_c__String__assign(&msg.data, buf);
  printf("Publishing: '%s'\n", buf);
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
}

// True once node/publisher/timer/executor creation has actually succeeded --
// see rclc_demo_tick() below.
static bool demo_ready = false;

// rmw_zenoh_pico's z_open() kicks off the WebSocket connection but can't
// block waiting for it to finish (no real thread to block on, and blocking
// the one JS-driven thread would freeze the page before the "open" event
// ever gets a chance to fire) -- so the very first rclc_node_init_default()
// call is *expected* to fail here, every time, regardless of how fast the
// router responds: the WebSocket "open" callback can only run once this
// synchronous call returns control to the JS event loop, which hasn't
// happened yet on the first attempt. rmw_zenoh_pico's own session_connect()
// (src/zenoh_pico/zenoh_pico_session.c) was written to expect exactly this
// -- a fresh z_owned_config_t each call, safe to retry from scratch -- so
// rclc_demo_tick() below just calls this again on later ticks until it
// stops failing, the same pattern this project's rclpy path already
// relies on (see pkg_additional_info.yaml's rmw_zenoh_pico build 28 note).
static bool rclc_demo_try_init(void)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();

  node = rcl_get_zero_initialized_node();
  if (rclc_node_init_default(&node, "wasm_zenoh_talker_rclc", "", &support) != RCL_RET_OK) {
    return false;
  }

  if (rclc_publisher_init_default(
        &publisher, &node,
        ROSIDL_GET_MSG_TYPE_SUPPORT(std_msgs, msg, String),
        "chatter") != RCL_RET_OK)
  {
    return false;
  }

  timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(500), timer_callback));

  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  std_msgs__msg__String__init(&msg);

  printf("wasm32 rclc talker ready, publishing on 'chatter' via rmw_zenoh_pico\n");
  return true;
}

// Called repeatedly from JS (see index_rclc.html) once main() has returned.
// Retries setup until the zenoh session is actually up (see
// rclc_demo_try_init() above), then does one rclc_executor_spin_some() per
// call -- the timeout here just bounds how long a single call may poll for
// incoming zenoh traffic before returning control to JS; it does not need
// to (and must not) block indefinitely.
EMSCRIPTEN_KEEPALIVE
void rclc_demo_tick(void)
{
  if (!demo_ready) {
    demo_ready = rclc_demo_try_init();
    return;
  }
  rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
}

int main(int argc, char const * const * argv)
{
  if (zenoh_connect_host[0] != '\0') {
    rmw_zenoh_pico_set_unicast(
      zenoh_connect_host,
      zenoh_connect_port[0] != '\0' ? zenoh_connect_port : NULL,
      NULL, NULL);
  }

  rcl_allocator_t allocator = rcl_get_default_allocator();
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  return 0;
}
