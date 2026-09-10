// wasm32 rclc "virtual robot" demo: subscribes to geometry_msgs/Twist on
// 'cmd_vel' -- the same topic both the keyboard (teleop_rclc.c) and
// phone-tilt (imu_rclc.c) demos publish on -- and dead-reckons a simple
// unicycle-model pose (x, y, theta) from it, so there's something to look
// at without needing real robot hardware.
//
// Same shared-memory architecture as the publisher demos, just the
// opposite direction: this worker thread integrates pose and writes it
// into wasm linear memory; index_robot_view.html (the real main thread,
// since canvas rendering needs DOM access the worker doesn't have) polls
// it on every animation frame to redraw a small robot icon.
#include <stdio.h>
#include <math.h>

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

rcl_subscription_t subscription;
geometry_msgs__msg__Twist cmd_vel_msg;

// Last-received velocity, applied continuously by the integration timer
// below rather than only on message receipt -- keeps the visualized
// motion smooth even if Twist messages arrive irregularly, same as a
// real motion-integration loop would.
static double current_linear_x = 0.0;
static double current_angular_z = 0.0;

// Read by index_robot_view.html every animation frame (main thread);
// written by the integration timer callback below (worker thread).
typedef struct {
  double x;
  double y;
  double theta;
} robot_pose_t;

static robot_pose_t robot_pose = {0.0, 0.0, 0.0};

EMSCRIPTEN_KEEPALIVE
robot_pose_t * robot_view_get_pose_ptr(void)
{
  return &robot_pose;
}

void cmd_vel_callback(const void * msgin)
{
  const geometry_msgs__msg__Twist * twist = (const geometry_msgs__msg__Twist *)msgin;
  current_linear_x = twist->linear.x;
  current_angular_z = twist->angular.z;
}

#define INTEGRATION_PERIOD_S 0.05 // 20 Hz

void integration_timer_callback(rcl_timer_t * timer, int64_t last_call_time, uintptr_t next_call_time)
{
  (void) next_call_time;
  (void) last_call_time;
  if (timer == NULL) {
    return;
  }
  // Simple unicycle model: integrate heading first, then position along
  // the new heading -- standard first-order dead reckoning, plenty
  // accurate for a demo running at 20 Hz.
  robot_pose.theta += current_angular_z * INTEGRATION_PERIOD_S;
  robot_pose.x += current_linear_x * cos(robot_pose.theta) * INTEGRATION_PERIOD_S;
  robot_pose.y += current_linear_x * sin(robot_pose.theta) * INTEGRATION_PERIOD_S;
}

int main(int argc, char const * const * argv)
{
  rcl_allocator_t allocator = rcl_get_default_allocator();
  rclc_support_t support;
  RCCHECK(rclc_support_init(&support, argc, argv, &allocator));

  rcl_node_t node = rcl_get_zero_initialized_node();
  RCCHECK(rclc_node_init_default(&node, "wasm_zenoh_robot_view_rclc", "", &support));

  subscription = rcl_get_zero_initialized_subscription();
  RCCHECK(rclc_subscription_init_default(
    &subscription, &node,
    ROSIDL_GET_MSG_TYPE_SUPPORT(geometry_msgs, msg, Twist),
    "cmd_vel"));

  rcl_timer_t integration_timer = rcl_get_zero_initialized_timer();
  RCCHECK(rclc_timer_init_default(
    &integration_timer, &support, RCL_MS_TO_NS((int)(INTEGRATION_PERIOD_S * 1000)),
    integration_timer_callback));

  // One subscription + one timer -> handle count 2.
  rclc_executor_t executor;
  RCCHECK(rclc_executor_init(&executor, &support.context, 2, &allocator));
  RCCHECK(rclc_executor_add_subscription(
    &executor, &subscription, &cmd_vel_msg, &cmd_vel_callback, ON_NEW_DATA));
  RCCHECK(rclc_executor_add_timer(&executor, &integration_timer));

  geometry_msgs__msg__Twist__init(&cmd_vel_msg);

  printf("wasm32 rclc robot_view demo starting, subscribing to Twist on 'cmd_vel' via rmw_zenoh_pico\n");
  printf("Drive it from the teleop or IMU demo pages.\n");

  while (true) {
    rclc_executor_spin_some(&executor, RCL_MS_TO_NS(20));
  }

  RCCHECK(rcl_subscription_fini(&subscription, &node));
  RCCHECK(rcl_node_fini(&node));

  return 0;
}
