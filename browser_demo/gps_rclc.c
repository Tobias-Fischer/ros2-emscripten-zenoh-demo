// wasm32 rclc GPS demo: the browser's Geolocation API drives a
// sensor_msgs/NavSatFix publisher on 'gps/fix'.
//
// Same architecture as teleop_rclc.c (see that file for the full
// rationale): -sPROXY_TO_PTHREAD=1 means main() runs on a pthread Web
// Worker with no window/DOM access, so navigator.geolocation.watchPosition
// lives entirely in plain JS in index_gps.html (the real main thread,
// no proxying needed), writing lat/lon/altitude directly into wasm linear
// memory. The worker-side timer callback just reads those doubles on its
// 1 Hz hot path -- no JS call needed there.
#include <stdio.h>
#include <string.h>

#include <emscripten.h>
#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <sensor_msgs/msg/nav_sat_fix.h>
#include <rosidl_runtime_c/string_functions.h>

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
sensor_msgs__msg__NavSatFix msg;

// Written by index_gps.html's navigator.geolocation.watchPosition
// callback (main thread), read every timer tick below (worker thread).
// has_fix stays 0 until the first real position arrives, so the demo
// never publishes a fake (0, 0) "Null Island" fix while waiting on the
// browser's location permission prompt.
typedef struct {
  double latitude;
  double longitude;
  double altitude; // NaN if the browser doesn't report one
  int32_t has_fix;
} gps_state_t;

static gps_state_t gps_state = {0.0, 0.0, 0.0, 0};

EMSCRIPTEN_KEEPALIVE
gps_state_t * gps_get_state_ptr(void)
{
  return &gps_state;
}

void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  if (!gps_state.has_fix) {
    return; // nothing real to publish yet
  }
  msg.latitude = gps_state.latitude;
  msg.longitude = gps_state.longitude;
  msg.altitude = gps_state.altitude;
  msg.status.status = sensor_msgs__msg__NavSatStatus__STATUS_FIX;
  msg.status.service = sensor_msgs__msg__NavSatStatus__SERVICE_GPS;
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
  printf("Publishing NavSatFix: lat=%.6f lon=%.6f alt=%.1f\n",
    msg.latitude, msg.longitude, msg.altitude);
}

int main(int argc, char const * const * argv)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_gps_rclc", "", &support));

  RCCHECK(rclc_publisher_init_default(
    &publisher, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(sensor_msgs, msg, NavSatFix),
    "gps/fix"));

  // 1 Hz: browser geolocation itself typically only updates every few
  // seconds anyway (and repeatedly publishing an unchanged fix is fine --
  // this is a demo, not a real nav stack).
  rcl_timer_t timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(1000), timer_callback));

  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  sensor_msgs__msg__NavSatFix__init(&msg);
  rosidl_runtime_c__String__assign(&msg.header.frame_id, "gps");

  printf("wasm32 rclc GPS demo starting, publishing NavSatFix on 'gps/fix' via rmw_zenoh_pico\n");
  printf("Waiting for the browser's Geolocation permission / first fix...\n");

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
  }

  RCCHECK(rcl_publisher_fini(&publisher, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
