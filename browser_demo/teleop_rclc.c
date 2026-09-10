// wasm32 rclc teleop: keyboard (WASD / arrow keys) drives a geometry_msgs/
// Twist publisher on 'cmd_vel'. Same structure as talker_rclc.c.
//
// This build uses -sPROXY_TO_PTHREAD=1 (see build_teleop.sh, matching
// talker_rclc's own build), so main() -- and this timer callback -- run
// on a pthread Web Worker, not the page's main thread. Workers have no
// `window`/DOM access, so keyboard handling can't live in C/EM_JS code
// called from the worker at all (tried MAIN_THREAD_EM_ASM* first: works
// in principle, but its macro internals turned out too fragile to get a
// multi-branch JS body through the C preprocessor's stringification/
// argument-balancing reliably). Instead: the *listener* lives entirely in
// plain JS in index_teleop.html (which always runs on the real main
// thread already, no proxying needed), writing directly into wasm linear
// memory -- a SharedArrayBuffer in a pthreads build, so the worker can
// read the same bytes with a plain C read, no cross-thread call needed on
// the hot (10 Hz) path either. teleop_get_state_ptr() below is the only
// thing exported for the HTML page to call, once, to find where to write.
#include <stdio.h>
#include <string.h>

#include <emscripten.h>
#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <geometry_msgs/msg/twist.h>

// RCL_RET_PUBLISHER_INVALID (300) is what every rcl_publish() call
// returns, over and over, whenever the wasm32 build can't reach a zenoh
// router at ws://127.0.0.1:7447 -- expected while none is running yet,
// not a crash, but "Failed status on line N: 300" reads like one, so
// spell out what it actually means instead of just the raw code.
#define RCCHECK(fn) { rcl_ret_t rc = fn; if (rc != RCL_RET_OK) { \
  if (rc == RCL_RET_PUBLISHER_INVALID) { \
    printf("Line %d: publisher invalid (rc=%d) -- usually means no zenoh router is reachable yet at ws://127.0.0.1:7447; start one (see the site's setup box).\n", __LINE__, (int)rc); \
  } else { \
    printf("Failed status on line %d: %d\n", __LINE__, (int)rc); \
  } } }

rcl_publisher_t publisher;
geometry_msgs__msg__Twist msg;

// Written by index_teleop.html's keydown/keyup listeners (main thread),
// read every timer tick below (worker thread) -- both sides just see
// ordinary wasm linear memory, backed by a SharedArrayBuffer.
typedef struct {
  double linear_x;
  double angular_z;
} teleop_state_t;

static teleop_state_t teleop_state = {0.0, 0.0};

EMSCRIPTEN_KEEPALIVE
teleop_state_t * teleop_get_state_ptr(void)
{
  return &teleop_state;
}

// Scales the -1/0/1 key state into m/s and rad/s -- deliberately modest so
// a runaway/stuck-key demo tab doesn't look alarming. Matches the scaling
// index_teleop.html's own listener applies before writing here.
void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  msg.linear.x = teleop_state.linear_x;
  msg.angular.z = teleop_state.angular_z;
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
}

int main(int argc, char const * const * argv)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_teleop_rclc", "", &support));

  RCCHECK(rclc_publisher_init_default(
    &publisher, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(geometry_msgs, msg, Twist),
    "cmd_vel"));

  // 10 Hz: responsive enough for manual driving, low enough to stay easy
  // to read in a browser console/log panel.
  rcl_timer_t timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(100), timer_callback));

  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  geometry_msgs__msg__Twist__init(&msg);

  printf("wasm32 rclc teleop starting, publishing Twist on 'cmd_vel' via rmw_zenoh_pico\n");
  printf("Use W/A/S/D or arrow keys to drive.\n");

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
  }

  RCCHECK(rcl_publisher_fini(&publisher, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
