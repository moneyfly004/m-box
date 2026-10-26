import 'server_pool.dart';

/// MBox 后端接口常量（cboard-go /api/v1，XBoard 兼容）
class Endpoints {
  Endpoints._();

  /// 当前生效的接口基底地址。
  ///
  /// 由 [ServerPool] 决定：默认走主域名（官网）；主域名在当前网络不可达时，
  /// ApiClient 会自动轮换到备用域名重试（备用域名是同一套后端，token 通用）。
  /// 域名池见 `server_pool.dart`，失败重试见 `api_client.dart`。
  static String get baseUrl => ServerPool.instance.activeBase;

  // 认证
  static const login = '/auth/login-json';
  static const refresh = '/auth/refresh';
  static const logout = '/auth/logout';
  static const register = '/auth/register';
  static const sendCode = '/auth/verification/send';
  static const verifyCode = '/auth/verification/verify';
  static const forgotPassword = '/auth/forgot-password';
  static const resetPassword = '/auth/reset-password';

  // 用户
  static const me = '/users/me';
  static const dashboardInfo = '/users/dashboard-info';
  static const devices = '/devices';

  // 订阅（XBoard 兼容）
  static const userSubscribe = '/user/subscribe'; // 返回 subscribe_url + 到期 + 设备数
  static const subscriptions = '/subscriptions/user-subscription';
  static const subscriptionsDevices = '/subscriptions/devices';
  /// 自助恢复：把被「踢下线」的本机重新登记回设备列表（无需重新登录）
  static const devicesRebind = '/subscriptions/devices/rebind';

  // 套餐 / 订单 / 支付
  static const packages = '/packages';
  static const orders = '/orders';
  // 设备增量升级（+N 台，可选 +M 天顺延；preview_only 时仅算价）
  static const ordersUpgradeDevices = '/orders/upgrade-devices';
  static const paymentMethods = '/payment/methods';
  static const payment = '/payment';
  static const couponsVerify = '/coupons/verify';

  // 节点
  static const nodes = '/nodes';
  static const nodesBatchTest = '/nodes/batch-test';

  // 通知 / 配置
  static const notifications = '/notifications';
  static const notificationsUnread = '/notifications/unread-count';
  static const softwareConfig = '/software-config';
  static const softwareVersions = '/software/versions';

  // 用户扩展
  static const changePassword = '/users/change-password';
  static const couponsMy = '/coupons/my';
}
