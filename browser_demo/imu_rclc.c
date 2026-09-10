// wasm32 rclc IMU-teleop demo: phone tilt (DeviceOrientation) drives a
// geometry_msgs/Twist publisher on 'cmd_vel' -- same topic and same
// message shape as teleop_rclc.c's keyboard version, so either one (or
// the robot_view demo's subscriber) can be swapped in without changing
// anything downstream.
//
// Same shared-memory architecture as teleop_rclc.c (see that file for
// the full rationale): DeviceOrientation is a main-thread-only browser
// API, main() runs on a pthread Web Worker, so the event listener lives
// in plain JS in index_imu.html, writing into wasm linear memory at the
// address imu_get_state_ptr() exports.
#include <stdio.h>
#include <string.h>

#include <emscripten.h>
#include <rcl/rcl.h>
#include <rclc/rclc.h>
#include <rclc/executor.h>
#include <geometry_msgs/msg/twist.h>

#define RCCHECK(fn) { rcl_ret_t rc = fn; if (rc != RCL_RET_OK) { \
  printf("Failed status on line %d: %d\n", __LINE__, (int)rc); } }

rcl_publisher_t publisher;
geometry_msgs__msg__Twist msg;

// Written by index_imu.html's deviceorientation listener (main thread),
// read every timer tick below (worker thread). has_orientation stays 0
// until the first real event arrives (or the user declines the iOS
// permission prompt), so this never publishes a phantom "moving" Twist
// before there's a real tilt reading.
typedef struct {
  double linear_x;
  double angular_z;
  int32_t has_orientation;
} imu_state_t;

static imu_state_t imu_state = {0.0, 0.0, 0};

EMSCRIPTEN_KEEPALIVE
imu_state_t * imu_get_state_ptr(void)
{
  return &imu_state;
}

void timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  if (!imu_state.has_orientation) {
    return; // nothing real to publish yet
  }
  msg.linear.x = imu_state.linear_x;
  msg.angular.z = imu_state.angular_z;
  RCCHECK(rcl_publish(&publisher, &msg, NULL));
}

int main(int argc, char const * const * argv)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_imu_rclc", "", &support));

  RCCHECK(rclc_publisher_init_default(
    &publisher, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(geometry_msgs, msg, Twist),
    "cmd_vel"));

  // 10 Hz, matching teleop_rclc.c.
  rcl_timer_t timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &timer, &support, RCL_MS_TO_NS(100), timer_callback));

  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 1, &allocator));
  RCCHECK(rclc_executor_add_timer(&executor, &timer));

  geometry_msgs__msg__Twist__init(&msg);

  printf("wasm32 rclc IMU-teleop demo starting, publishing Twist on 'cmd_vel' via rmw_zenoh_pico\n");
  printf("Waiting for device orientation permission / first reading...\n");

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(100));
  }

  RCCHECK(rcl_publisher_fini(&publisher, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
