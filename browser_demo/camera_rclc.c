// wasm32 rclc camera demo: the browser's webcam (or, if unavailable, a
// synthetic animated test pattern) drives a sensor_msgs/Image publisher
// on 'camera/image'.
//
// Same architecture as teleop_rclc.c / gps_rclc.c (see teleop_rclc.c for
// the full rationale): -sPROXY_TO_PTHREAD=1 means main() runs on a
// pthread Web Worker with no DOM/getUserMedia access, so all the canvas
// capture lives in plain JS in index_camera.html (the real main thread),
// writing raw RGB8 pixels directly into wasm linear memory. The
// worker-side timer callback just publishes whatever's currently there,
// unlike teleop/gps there's no "has data yet" flag needed for this one --
// the test-pattern fallback means there's always *something* real to
// publish, camera permission or not.
//
// Fixed at a small, deliberately modest resolution: this is a demo over
// a browser WebSocket, not a real camera driver, and RGB8 has no
// compression (160x120x3 = 57600 bytes/frame already).
#include <stdio.h>
#include <string.h>

#include <emscripten.h>
#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <sensor_msgs/msg/image.h>
#include <rosidl_runtime_c/string_functions.h>
#include <rosidl_runtime_c/primitives_sequence_functions.h>

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

#define IMG_WIDTH 160
#define IMG_HEIGHT 120
#define IMG_CHANNELS 3

rcl_publisher_t publisher;
sensor_msgs__msg__Image msg;

// index_camera.html writes raw RGB8 pixels here every animation frame
// (main thread, from a <video>/getUserMedia frame or the synthetic
// fallback pattern -- either way, the same fixed-size buffer); the
// worker-side timer callback below just publishes whatever's currently
// there, at its own independent rate.
EMSCRIPTEN_KEEPALIVE
uint8_t * camera_get_frame_buffer_ptr(void)
{
  return msg.data.data;
}

void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
}

int main(int argc, char const * const * argv)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_camera_rclc", "", &support));

  RCCHECK(rclc_publisher_init_default(
    &publisher, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(sensor_msgs, msg, Image),
    "camera/image"));

  // 2 Hz: plenty to see it's live, without flooding a websocket with
  // uncompressed frames.
  rcl_timer_t timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(500), timer_callback));

  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  sensor_msgs__msg__Image__init(&msg);
  rosidl_runtime_c__String__assign(&msg.header.frame_id, "camera");
  rosidl_runtime_c__String__assign(&msg.encoding, "rgb8");
  msg.height = IMG_HEIGHT;
  msg.width = IMG_WIDTH;
  msg.step = IMG_WIDTH * IMG_CHANNELS;
  msg.is_bigendian = 0;
  if (!rosidl_runtime_c__uint8__Sequence__init(&msg.data, (size_t)IMG_WIDTH * IMG_HEIGHT * IMG_CHANNELS)) {
    printf("Failed to allocate image buffer\n");
    return 1;
  }
  // Filled in only once JS starts writing frames -- publish a visibly
  // "not a real frame yet" mid-gray until then, not stale zeroed memory.
  memset(msg.data.data, 128, msg.data.size);

  printf("wasm32 rclc camera demo starting, publishing %dx%d Image on 'camera/image' via rmw_zenoh_pico\n",
    IMG_WIDTH, IMG_HEIGHT);

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
  }

  RCCHECK(rcl_publisher_fini(&publisher, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
