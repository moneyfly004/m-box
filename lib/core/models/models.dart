/// 数据模型（与 myweb 后端字段逐一对齐）
library;

// ============ 用户 ============
class UserInfo {
  final int id;
  final String username;
  final String email;
  final double balance;
  final bool isAdmin;
  /// 账号是否启用（后端 users.is_active；禁用账号 = 被管理员封禁，
  /// 无法使用任何服务。登录接口不返回该字段，默认按启用处理）
  final bool isActive;

  UserInfo({
    required this.id,
    required this.username,
    required this.email,
    required this.balance,
    this.isAdmin = false,
    this.isActive = true,
  });

  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        username: j['username']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        balance: double.tryParse(j['balance']?.toString() ?? '') ?? (j['balance'] as num?)?.toDouble() ?? 0,
        isAdmin: j['is_admin'] == true,
        isActive: j['is_active'] != false,
      );
}

/// /users/dashboard-info 返回（我的页数据源）
class DashboardInfo {
  final String username;
  final String email;
  final double balance;
  final String membership;
  final int onlineDevices;
  final int totalDevices;
  final String subscriptionStatus;
  final String expireTime;
  final int remainingDays;
  final bool hasSpecialNodes;
  /// 账号是否启用（users.is_active；false = 账号被禁用）
  final bool isActive;

  DashboardInfo({
    required this.username,
    required this.email,
    required this.balance,
    required this.membership,
    required this.onlineDevices,
    required this.totalDevices,
    required this.subscriptionStatus,
    required this.expireTime,
    required this.remainingDays,
    required this.hasSpecialNodes,
    this.isActive = true,
  });

  factory DashboardInfo.fromJson(Map<String, dynamic> j) => DashboardInfo(
        username: j['username']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        balance: double.tryParse(j['balance']?.toString() ?? '') ?? 0,
        membership: j['membership']?.toString() ?? '',
        onlineDevices: (j['online_devices'] as num?)?.toInt() ?? 0,
        totalDevices: (j['total_devices'] as num?)?.toInt() ?? 0,
        subscriptionStatus: j['subscription_status']?.toString() ?? '',
        expireTime: j['expire_time']?.toString() ?? '未设置',
        remainingDays: (j['remaining_days'] as num?)?.toInt() ?? 0,
        hasSpecialNodes: j['has_special_nodes'] == true,
        isActive: j['is_active'] != false,
      );

  /// 订阅是否生效（后端 subscription_status: active / inactive / disabled 等，
  /// 只有 active 视为生效；未设置视为无订阅）
  bool get hasSubscription => subscriptionStatus == 'active';

  /// 序列化（本地磁盘缓存用），字段名与后端 JSON 一致
  Map<String, dynamic> toJson() => {
        'username': username,
        'email': email,
        'balance': balance,
        'membership': membership,
        'online_devices': onlineDevices,
        'total_devices': totalDevices,
        'subscription_status': subscriptionStatus,
        'expire_time': expireTime,
        'remaining_days': remainingDays,
        'has_special_nodes': hasSpecialNodes,
        'is_active': isActive,
      };
}

// ============ 订阅 ============
/// /user/subscribe（XBoard 兼容）
class SubscriptionInfo {
  final String subscribeUrl;
  final String? universalUrl;

  /// 备用订阅地址（后端 subscription_backup_domains 下发的其它域名，token 相同、配置一致）。
  /// 主地址在当前网络打不开时（域名被墙/线路不通），按顺序尝试这些地址即可拿到同一份订阅。
  /// 轮换逻辑见 `services/subscribe_url_failover.dart`。
  final List<String> subscribeUrls;
  final DateTime? expireTime;
  final int deviceLimit;
  final int currentDevices;
  final int remainingDays;
  final bool isExpired;
  final String status;
  /// 订阅是否启用（后端 subscriptions.is_active；false = 订阅被管理员停用）
  final bool isActive;

  SubscriptionInfo({
    required this.subscribeUrl,
    this.universalUrl,
    this.subscribeUrls = const [],
    this.expireTime,
    required this.deviceLimit,
    required this.currentDevices,
    required this.remainingDays,
    required this.isExpired,
    required this.status,
    this.isActive = true,
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) {
    final et = j['expire_time']?.toString();
    final rawList = j['subscribe_urls'];
    return SubscriptionInfo(
      subscribeUrl: j['subscribe_url']?.toString() ?? '',
      universalUrl: j['universal_url']?.toString(),
      subscribeUrls: rawList is List
          ? [
              for (final u in rawList)
                if (u != null && u.toString().trim().isNotEmpty) u.toString().trim(),
            ]
          : const [],
      expireTime: (et == null || et.isEmpty) ? null : DateTime.tryParse(et),
      deviceLimit: (j['device_limit'] as num?)?.toInt() ?? 0,
      currentDevices: (j['current_devices'] as num?)?.toInt() ?? 0,
      remainingDays: (j['remaining_days'] as num?)?.toInt() ?? 0,
      isExpired: j['is_expired'] == true,
      status: j['status']?.toString() ?? '',
      isActive: j['is_active'] != false,
    );
  }

  /// 订阅真正生效（启用 + 状态 active + 未过期 + 有订阅地址）
  /// status 比较不区分大小写：后端若把 `active` 写成 `Active`/`ACTIVE`，
  /// 旧实现会判为「未生效」→ 走 _dropAllCaches() 清空订阅缓存，用户表现为
  /// 「订阅突然全没了」。
  bool get hasSubscription =>
      subscribeUrl.isNotEmpty &&
      isActive &&
      (status.isEmpty || status.toLowerCase() == 'active') &&
      !isExpired;
}

// ============ 套餐 / 支付 ============
class Plan {
  final int id;
  final String name;
  final String? description;
  final double price;
  final int durationDays;
  final int deviceLimit;
  final bool isRecommended;

  Plan({
    required this.id,
    required this.name,
    this.description,
    required this.price,
    required this.durationDays,
    required this.deviceLimit,
    required this.isRecommended,
  });

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name']?.toString() ?? '',
        description: j['description']?.toString(),
        price: (j['price'] as num?)?.toDouble() ?? 0,
        durationDays: (j['duration_days'] as num?)?.toInt() ?? 0,
        deviceLimit: (j['device_limit'] as num?)?.toInt() ?? 0,
        isRecommended: j['is_recommended'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'price': price,
        'duration_days': durationDays,
        'device_limit': deviceLimit,
        'is_recommended': isRecommended,
      };
}

class PayMethod {
  final int id;
  final String payType;
  final String name;
  final int sortOrder;

  PayMethod({required this.id, required this.payType, required this.name, required this.sortOrder});

  factory PayMethod.fromJson(Map<String, dynamic> j) => PayMethod(
        id: (j['id'] as num?)?.toInt() ?? 0,
        // 实测后端返回字段为 key（如 alipay / wechat / yipay_alipay / usdt），
        // 兼容历史 pay_type 字段
        payType: j['key']?.toString() ?? j['pay_type']?.toString() ?? '',
        name: j['name']?.toString() ?? j['key']?.toString() ?? '',
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );

  bool get isAlipay => payType.contains('alipay');
  bool get isWechat => payType.contains('wechat') || payType.contains('wxpay');
  bool get isCrypto => payType.contains('usdt') || payType.contains('crypto');

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': payType,
        'name': name,
        'sort_order': sortOrder,
      };
}

class PaymentResult {
  final String qrCode;
  final String orderNo;
  final String status;

  PaymentResult({required this.qrCode, required this.orderNo, required this.status});

  factory PaymentResult.fromJson(Map<String, dynamic> j) => PaymentResult(
        qrCode: j['payment_qr_code']?.toString() ?? j['qrcode']?.toString() ?? '',
        orderNo: j['order_no']?.toString() ?? j['orderNo']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
      );
}

// ============ 订单 ============
class OrderItem {
  final int id;
  final String orderNo;
  final double amount;
  final double finalAmount;
  final String status;
  final String type;
  final String? packageName;
  final String? paymentMethodName;
  final String createdAt;

  OrderItem({
    required this.id,
    required this.orderNo,
    required this.amount,
    required this.finalAmount,
    required this.status,
    required this.type,
    this.packageName,
    this.paymentMethodName,
    required this.createdAt,
  });

  factory OrderItem.fromJson(Map<String, dynamic> j) {
    final orderData = j['order'] is Map ? j['order'] as Map : j;
    final packageData = j['package'] is Map ? j['package'] as Map : null;
    return OrderItem(
      id: (orderData['id'] as num?)?.toInt() ?? (j['id'] as num?)?.toInt() ?? 0,
      orderNo: orderData['order_no']?.toString() ?? j['order_no']?.toString() ?? '',
      amount: (orderData['amount'] as num?)?.toDouble() ?? (j['amount'] as num?)?.toDouble() ?? 0,
      finalAmount: (orderData['final_amount'] as num?)?.toDouble() ?? 0,
      status: orderData['status']?.toString() ?? j['status']?.toString() ?? '',
      type: orderData['type']?.toString() ?? 'order',
      packageName: packageData?['name']?.toString() ?? j['package_name']?.toString(),
      paymentMethodName: j['payment_method_name']?.toString() ?? orderData['payment_method_name']?.toString(),
      createdAt: j['created_at']?.toString() ?? orderData['created_at']?.toString() ?? '',
    );
  }

  String get statusLabel => switch (status) {
        'pending' => '待支付',
        'paid' => '已支付',
        'cancelled' => '已取消',
        'expired' => '已过期',
        'failed' => '失败',
        _ => status,
      };
}

/// 订单状态查询结果
class OrderStatus {
  final String orderNo;
  final String status;
  final double amount;
  final double finalAmount;
  final String type;

  OrderStatus({
    required this.orderNo,
    required this.status,
    required this.amount,
    required this.finalAmount,
    required this.type,
  });

  factory OrderStatus.fromJson(Map<String, dynamic> j) => OrderStatus(
        orderNo: j['order_no']?.toString() ?? j['orderNo']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        finalAmount: (j['final_amount'] as num?)?.toDouble() ?? 0,
        type: j['type']?.toString() ?? 'order',
      );

  bool get isPaid => status == 'paid';
}

// ============ 设备 ============
class DeviceInfo {
  final int id;
  final int? subscriptionId;
  final String deviceName;
  final String deviceType;
  final String deviceModel;
  final String deviceBrand;
  /// 硬件指纹哈希（后端字段 device_hw_fp，来自客户端上报的 X-MF-Device-Fp）。
  /// 用于在设备列表里**精确**认出本机：同型号两台电脑的机型/品牌完全一样，
  /// 只看机型会把别人的机器误标成「本机」。老后端不下发此字段时为空串，
  /// 调用方应退回机型+品牌启发式判断。
  final String deviceHwFp;
  final String ipAddress;
  final String location;
  final String osName;
  final String osVersion;
  final String softwareName;
  final String softwareVersion;
  final bool isActive;
  final bool isAllowed;
  /// 设备是否在线（后端按最近访问时间窗口计算；与 is_active（注册启用）
  /// 区分：is_active 只增不减导致「永久在线」，online 才反映真实活跃状态）
  final bool online;
  /// 后端按「设备自己的回拉节奏」算出的三档状态：active / recent / offline。
  /// 比 online 布尔更细（活跃 / 近期用过 / 离线），列表直接显示中文标签。
  final String activityState;
  final String activityStateLabel;
  /// 距最近一次拉订阅的秒数（负数/缺省表示未知），用于显示「X 前」
  final int activityAgoSeconds;
  final String lastSeen;
  final String lastAccess;
  final String firstSeen;
  final int accessCount;
  final String remark;

  DeviceInfo({
    required this.id,
    this.subscriptionId,
    required this.deviceName,
    required this.deviceType,
    required this.deviceModel,
    required this.deviceBrand,
    this.deviceHwFp = '',
    required this.ipAddress,
    required this.location,
    required this.osName,
    required this.osVersion,
    required this.softwareName,
    required this.softwareVersion,
    required this.isActive,
    required this.isAllowed,
    this.online = false,
    this.activityState = '',
    this.activityStateLabel = '',
    this.activityAgoSeconds = -1,
    required this.lastSeen,
    required this.lastAccess,
    required this.firstSeen,
    required this.accessCount,
    required this.remark,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        subscriptionId: (j['subscription_id'] as num?)?.toInt(),
        // /subscriptions/devices 有 name/ip/type 冗余别名
        deviceName: j['device_name']?.toString() ?? j['name']?.toString() ?? '',
        deviceType: j['device_type']?.toString() ?? j['type']?.toString() ?? '',
        deviceModel: j['device_model']?.toString() ?? '',
        deviceBrand: j['device_brand']?.toString() ?? '',
        deviceHwFp: j['device_hw_fp']?.toString() ?? '',
        ipAddress: j['ip_address']?.toString() ?? j['ip']?.toString() ?? '',
        location: j['location']?.toString() ?? '',
        osName: j['os_name']?.toString() ?? '',
        osVersion: j['os_version']?.toString() ?? '',
        softwareName: j['software_name']?.toString() ?? '',
        softwareVersion: j['software_version']?.toString() ?? '',
        isActive: j['is_active'] == true,
        isAllowed: j['is_allowed'] == true,
        // online：后端新字段（按最近访问窗口计算）。老后端缺失时用
        // is_active 兜底，避免升级过渡期整列表误判离线。
        online: j['online'] == true ||
            (j['online'] == null && j['is_active'] == true),
        activityState: j['activity_state']?.toString() ?? '',
        activityStateLabel: j['activity_state_label']?.toString() ?? '',
        activityAgoSeconds: (j['activity_ago_seconds'] as num?)?.toInt() ?? -1,
        lastSeen: j['last_seen']?.toString() ?? '',
        lastAccess: j['last_access']?.toString() ?? '',
        firstSeen: j['first_seen']?.toString() ?? '',
        accessCount: (j['access_count'] as num?)?.toInt() ?? 0,
        remark: j['remark']?.toString() ?? '',
      );

  String get displayName => deviceName.isNotEmpty ? deviceName : (osName.isNotEmpty ? osName : '未知设备');
}

/// 设备列表响应里的「是否允许用户删除设备」开关（后台：系统设置 → 用户与注册）。
///
/// 后端在 `GET /subscriptions/devices` 的 data 里随列表实时下发
/// `allow_delete_device`（true = 用户端显示删除按钮；false = 不显示，改为引导
/// 升级设备数量）。后端 `DELETE /devices/:id` 也会按同一开关做服务端拦截。
///
/// **安全默认 false**：字段缺失（旧后端 / XBoard 兼容返回 / 无订阅时后端返回
/// 空数组）或类型异常时一律按「不可删除」处理 —— 宁可不显示删除入口，也不能
/// 让用户点了才被 403 拒绝（那种「按钮点了报错」的体验等同于 bug）。
bool parseAllowDeleteDevice(dynamic body) {
  if (body is! Map) return false;
  final v = body['allow_delete_device'];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.trim().toLowerCase() == 'true';
  return false;
}

/// 设备列表 + 删除策略：一次请求同时拿到列表与开关，避免页面渲染时
/// 「列表已到、开关未到」的中间态（否则会出现删除按钮闪一下又消失）。
class DeviceListResult {
  const DeviceListResult({required this.devices, required this.allowDelete});

  final List<DeviceInfo> devices;

  /// 是否允许删除设备（见 [parseAllowDeleteDevice]，默认 false）。
  final bool allowDelete;

  static const empty = DeviceListResult(devices: [], allowDelete: false);
}

// ============ 通知 ============
class AppNotification {
  final int id;
  final String title;
  final String content;
  final String type;
  final bool isRead;
  final String createdAt;

  AppNotification({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: j['title']?.toString() ?? '',
        content: j['content']?.toString() ?? '',
        type: j['type']?.toString() ?? 'system',
        isRead: j['is_read'] == true,
        createdAt: j['created_at']?.toString() ?? '',
      );
}

// ============ 优惠券 ============
class Coupon {
  final int id;
  final String code;
  final String name;
  final String discountType;
  final double discountValue;
  final double minAmount;
  final String? expireTime;
  final bool isActive;

  Coupon({
    required this.id,
    required this.code,
    required this.name,
    required this.discountType,
    required this.discountValue,
    required this.minAmount,
    this.expireTime,
    required this.isActive,
  });

  factory Coupon.fromJson(Map<String, dynamic> j) => Coupon(
        id: (j['id'] as num?)?.toInt() ?? 0,
        code: j['code']?.toString() ?? '',
        name: j['name']?.toString() ?? j['code']?.toString() ?? '',
        discountType: j['discount_type']?.toString() ?? 'percent',
        discountValue: (j['discount_value'] as num?)?.toDouble() ?? 0,
        minAmount: (j['min_amount'] as num?)?.toDouble() ?? 0,
        expireTime: j['expire_time']?.toString(),
        isActive: j['is_active'] != false,
      );

  /// 计算折后金额
  double applyTo(double amount) {
    if (discountType == 'fixed') return (amount - discountValue).clamp(0.01, amount);
    return (amount * (1 - discountValue / 100)).clamp(0.01, amount);
  }
}

// ============ 节点（Clash 订阅解析结果） ============
class ProxyNode {
  final String tag;
  final String type;
  final String server;
  final int port;
  final String? region;
  final String? countryCode;
  final String? uuid;
  final String? cipher;
  final String? password;
  final bool? tls;
  final String? sni;
  final String? network;
  final String? wsPath;
  final String? host;
  final String? flow;
  final Map<String, dynamic> raw;
  int latencyMs; // -1 未测
  bool online;

  ProxyNode({
    required this.tag,
    required this.type,
    required this.server,
    required this.port,
    this.region,
    this.countryCode,
    this.uuid,
    this.cipher,
    this.password,
    this.tls,
    this.sni,
    this.network,
    this.wsPath,
    this.host,
    this.flow,
    Map<String, dynamic>? raw,
    this.latencyMs = -1,
    this.online = true,
  }) : raw = raw ?? {};

  /// 克隆（含当前测速状态）。测速/列表替换用副本，避免把结果就地写进
  /// 正在被 UI/内核引用的节点对象（断开瞬间在途测速会把整批标离线）。
  ProxyNode clone() => ProxyNode(
        tag: tag,
        type: type,
        server: server,
        port: port,
        region: region,
        countryCode: countryCode,
        uuid: uuid,
        cipher: cipher,
        password: password,
        tls: tls,
        sni: sni,
        network: network,
        wsPath: wsPath,
        host: host,
        flow: flow,
        raw: Map<String, dynamic>.from(raw),
        latencyMs: latencyMs,
        online: online,
      );

  /// 是否 UDP-only 协议（hysteria / hysteria2 / tuic / wireguard）。
  /// 这类协议无 TCP 监听，未连接时的「裸 TCP 测速」必然失败而误判离线；
  /// 真实延迟需走内核 /proxies/{tag}/delay 实测。
  bool get isUdpOnly =>
      const {'hysteria', 'hysteria2', 'tuic', 'wireguard'}.contains(type);

  /// 是否为面板展示性伪节点（见 [isPanelPseudoNode]）。
  bool get isPanelPseudo => isPanelPseudoNode(tag, server);

  /// 国家/地区中文名（ISO 3166 两位码）。覆盖 VPN 服务商常见的全部落地区域;
  /// 未收录的合法代码 UI 直接显示代码本身，旗帜由 [flagEmoji] 按码计算，
  /// 不会再出现「节点存在但归到『其他』」的情况。
  static const countryNames = {
    // 东亚
    'HK': '香港', 'MO': '澳门', 'TW': '台湾', 'JP': '日本', 'KR': '韩国',
    'CN': '中国', 'MN': '蒙古',
    // 东南亚
    'SG': '新加坡', 'VN': '越南', 'TH': '泰国', 'PH': '菲律宾',
    'MY': '马来西亚', 'ID': '印尼', 'KH': '柬埔寨', 'LA': '老挝',
    'MM': '缅甸', 'BN': '文莱',
    // 南亚
    'IN': '印度', 'PK': '巴基斯坦', 'BD': '孟加拉', 'LK': '斯里兰卡',
    'NP': '尼泊尔', 'BT': '不丹', 'MV': '马尔代夫',
    // 中亚
    'KZ': '哈萨克斯坦', 'UZ': '乌兹别克斯坦', 'KG': '吉尔吉斯斯坦',
    'TJ': '塔吉克斯坦', 'TM': '土库曼斯坦',
    // 中东
    'AE': '阿联酋', 'TR': '土耳其', 'SA': '沙特阿拉伯', 'QA': '卡塔尔',
    'KW': '科威特', 'BH': '巴林', 'OM': '阿曼', 'JO': '约旦',
    'IL': '以色列', 'LB': '黎巴嫩', 'IQ': '伊拉克', 'IR': '伊朗',
    'SY': '叙利亚', 'YE': '也门',
    // 欧亚 / 高加索
    'RU': '俄罗斯', 'UA': '乌克兰', 'BY': '白俄罗斯', 'GE': '格鲁吉亚',
    'AM': '亚美尼亚', 'AZ': '阿塞拜疆', 'MD': '摩尔多瓦',
    // 欧洲
    'DE': '德国', 'NL': '荷兰', 'FR': '法国', 'CH': '瑞士', 'GB': '英国',
    'IE': '爱尔兰', 'SE': '瑞典', 'FI': '芬兰', 'NO': '挪威', 'DK': '丹麦',
    'IS': '冰岛', 'PL': '波兰', 'IT': '意大利', 'ES': '西班牙',
    'PT': '葡萄牙', 'AT': '奥地利', 'BE': '比利时', 'LU': '卢森堡',
    'CZ': '捷克', 'SK': '斯洛伐克', 'HU': '匈牙利', 'GR': '希腊',
    'RO': '罗马尼亚', 'BG': '保加利亚', 'RS': '塞尔维亚', 'HR': '克罗地亚',
    'SI': '斯洛文尼亚', 'EE': '爱沙尼亚', 'LT': '立陶宛', 'LV': '拉脱维亚',
    'MT': '马耳他', 'CY': '塞浦路斯', 'MK': '北马其顿', 'AL': '阿尔巴尼亚',
    'BA': '波黑', 'ME': '黑山', 'GI': '直布罗陀', 'LI': '列支敦士登',
    'MC': '摩纳哥', 'AD': '安道尔', 'SM': '圣马力诺',
    // 大洋洲
    'AU': '澳大利亚', 'NZ': '新西兰', 'FJ': '斐济', 'GU': '关岛',
    // 北美 / 加勒比
    'US': '美国', 'CA': '加拿大', 'MX': '墨西哥', 'PA': '巴拿马',
    'CR': '哥斯达黎加', 'GT': '危地马拉', 'HN': '洪都拉斯',
    'SV': '萨尔瓦多', 'NI': '尼加拉瓜', 'DO': '多米尼加',
    'PR': '波多黎各', 'JM': '牙买加', 'CU': '古巴', 'BS': '巴哈马',
    'BZ': '伯利兹', 'TT': '特立尼达和多巴哥', 'BB': '巴巴多斯',
    'KY': '开曼群岛', 'BM': '百慕大', 'VG': '英属维尔京',
    // 南美
    'BR': '巴西', 'CL': '智利', 'AR': '阿根廷', 'CO': '哥伦比亚',
    'PE': '秘鲁', 'VE': '委内瑞拉', 'EC': '厄瓜多尔', 'UY': '乌拉圭',
    'PY': '巴拉圭', 'BO': '玻利维亚',
    // 非洲
    'ZA': '南非', 'EG': '埃及', 'MA': '摩洛哥', 'TN': '突尼斯',
    'DZ': '阿尔及利亚', 'LY': '利比亚', 'NG': '尼日利亚', 'KE': '肯尼亚',
    'ET': '埃塞俄比亚', 'GH': '加纳', 'TZ': '坦桑尼亚', 'UG': '乌干达',
    'AO': '安哥拉', 'ZW': '津巴布韦', 'SN': '塞内加尔', 'CM': '喀麦隆',
    'RW': '卢旺达', 'MU': '毛里求斯', 'SC': '塞舌尔',
  };

  /// 由 ISO 两位码计算国旗 emoji（区域指示符拼合），任意国家零维护;
  /// 无效码 / 'XX'（未识别）回退地球图标。
  static String flagEmoji(String? code) {
    final c = code?.toUpperCase();
    if (c == null || c.length != 2 || c == 'XX') return '\u{1F310}';
    final a = c.codeUnitAt(0), b = c.codeUnitAt(1);
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return '\u{1F310}';
    return String.fromCharCodes([0x1F1E6 + a - 0x41, 0x1F1E6 + b - 0x41]);
  }

  String get flag => flagEmoji(countryCode);

  /// 展示名：已收录 → 中文名；合法但未收录 → 代码本身（不再一律「其他」）
  String get regionName {
    final c = countryCode?.toUpperCase();
    if (c == null || c == 'XX') return '其他';
    return countryNames[c] ?? c;
  }

  /// 节点列表国家/地区展示顺序：热门在前（港·日·新·美，用户指定），
  /// 其余按「距中国远近」由近及远。三端节点列表统一用此顺序。
  static const countryOrder = <String>[
    // 热门（固定置顶顺序）
    'HK', 'JP', 'SG', 'US',
    // 东亚近邻
    'TW', 'KR', 'MO', 'CN', 'MN',
    // 东南亚
    'VN', 'TH', 'PH', 'MY', 'ID', 'KH', 'LA', 'MM', 'BN',
    // 南亚
    'IN', 'PK', 'BD', 'LK', 'NP', 'BT', 'MV',
    // 中亚
    'KZ', 'UZ', 'KG', 'TJ', 'TM',
    // 中东
    'AE', 'TR', 'SA', 'QA', 'KW', 'BH', 'OM', 'JO', 'IL', 'LB',
    'IQ', 'IR', 'SY', 'YE',
    // 欧亚 / 东欧 / 高加索
    'RU', 'UA', 'BY', 'GE', 'AM', 'AZ', 'MD',
    // 欧洲
    'DE', 'NL', 'FR', 'CH', 'GB', 'IE', 'SE', 'FI', 'NO', 'DK', 'IS',
    'PL', 'IT', 'ES', 'PT', 'AT', 'BE', 'LU', 'CZ', 'SK', 'HU', 'GR',
    'RO', 'BG', 'RS', 'HR', 'SI', 'EE', 'LT', 'LV', 'MT', 'CY', 'MK',
    'AL', 'BA', 'ME', 'GI', 'LI', 'MC', 'AD', 'SM',
    // 大洋洲
    'AU', 'NZ', 'FJ', 'GU',
    // 北美 / 加勒比（美国已置顶）
    'CA', 'MX', 'PA', 'CR', 'GT', 'HN', 'SV', 'NI', 'DO', 'PR', 'JM',
    'CU', 'BS', 'BZ', 'TT', 'BB', 'KY', 'BM', 'VG',
    // 南美
    'BR', 'CL', 'AR', 'CO', 'PE', 'VE', 'EC', 'UY', 'PY', 'BO',
    // 非洲
    'ZA', 'EG', 'MA', 'TN', 'DZ', 'LY', 'NG', 'KE', 'ET', 'GH', 'TZ',
    'UG', 'AO', 'ZW', 'SN', 'CM', 'RW', 'MU', 'SC',
  ];

  /// 国家排序权重：越小越靠前。已列入按其位次；合法但未列入的代码按
  /// 字母序稳定分组（200~875，保证同国节点聚在一起且排在「未知」前）；
  /// 未知（null/XX/非法）→ 999 恒最后。
  static int countryRank(String? code) {
    if (code == null || code.length != 2) return 999;
    final c = code.toUpperCase();
    if (c == 'XX') return 999;
    final i = countryOrder.indexOf(c);
    if (i >= 0) return i;
    final a = c.codeUnitAt(0) - 0x41, b = c.codeUnitAt(1) - 0x41;
    if (a < 0 || a > 25 || b < 0 || b > 25) return 999;
    return 200 + a * 26 + b;
  }

  /// 节点列表统一比较器：国家（距中国远近/热门）→ 在线优先 → 延迟升序 → 名称。
  /// 同一国家内在线且低延迟的排前，未测速/离线的靠后。
  static int compareForList(ProxyNode a, ProxyNode b) {
    final ra = countryRank(a.countryCode);
    final rb = countryRank(b.countryCode);
    if (ra != rb) return ra.compareTo(rb);
    if (a.online != b.online) return a.online ? -1 : 1;
    final la = a.latencyMs, lb = b.latencyMs;
    if (la < 0 && lb < 0) return a.tag.compareTo(b.tag);
    if (la < 0) return 1;
    if (lb < 0) return -1;
    if (la != lb) return la.compareTo(lb);
    return a.tag.compareTo(b.tag);
  }

  /// 由 Clash YAML 节点 map 构造
  factory ProxyNode.fromClashMap(Map<String, dynamic> m) {
    final tag = m['name']?.toString() ?? '未命名节点';
    final server = m['server']?.toString() ?? '';
    final port = (m['port'] as num?)?.toInt() ?? 0;
    final region = m['region']?.toString() ?? m['country']?.toString();
    final countryCode = m['country-code']?.toString() ?? _inferCountry(tag, region);
    return ProxyNode(
      tag: tag,
      type: m['type']?.toString() ?? 'vless',
      server: server,
      port: port,
      region: region,
      countryCode: countryCode,
      uuid: m['uuid']?.toString(),
      cipher: m['cipher']?.toString(),
      password: m['password']?.toString(),
      tls: m['tls'] == true,
      sni: m['servername']?.toString() ?? m['sni']?.toString(),
      network: m['network']?.toString(),
      wsPath: m['ws-opts'] is Map ? (m['ws-opts'] as Map)['path']?.toString() : null,
      host: m['ws-opts'] is Map && (m['ws-opts'] as Map)['headers'] is Map
          ? ((m['ws-opts'] as Map)['headers'] as Map)['Host']?.toString()
          : null,
      flow: m['flow']?.toString(),
      raw: Map<String, dynamic>.from(m),
    );
  }

  /// 短代码匹配（jp-1、US_02、hk01、sg-premium 等）。
  /// 两侧必须是非字母（避免 CHINA 误匹配 IN）。刻意排除的高误判码：
  ///  - CN：节点名常见「CN2/CN2 GIA」线路标注，会整批误判成中国
  ///  - LA：美国节点常用 LA 指洛杉矶，不能按老挝解析
  ///  - ME：常被用作「中东/Middle East」区域缩写，黑山只认全称
  ///  - BT：中文节点常见「禁BT」标注，不丹只认全称
  static final _prefixCodeRe = RegExp(
    r'(?:^|[^A-Z])('
    r'HK|MO|TW|JP|KR|MN'
    r'|SG|VN|TH|PH|MY|ID|KH|MM|BN'
    r'|IN|PK|BD|LK|NP|MV'
    r'|KZ|UZ|KG|TJ|TM'
    r'|AE|TR|SA|QA|KW|BH|OM|JO|IL|LB|IQ|IR|SY|YE'
    r'|RU|UA|BY|GE|AM|AZ|MD'
    r'|DE|NL|FR|CH|GB|UK|IE|SE|FI|NO|DK|IS|PL|IT|ES|PT|AT|BE|LU'
    r'|CZ|SK|HU|GR|RO|BG|RS|HR|SI|EE|LT|LV|MT|CY|MK|AL|BA|GI|LI|MC|AD|SM'
    r'|AU|NZ|FJ|GU'
    r'|US|CA|MX|PA|CR|GT|HN|SV|NI|DO|PR|JM|CU|BS|BZ|TT|BB|KY|BM|VG'
    r'|BR|CL|AR|CO|PE|VE|EC|UY|PY|BO'
    r'|ZA|EG|MA|TN|DZ|LY|NG|KE|ET|GH|TZ|UG|AO|ZW|SN|CM|RW|MU|SC'
    r')(?:$|[^A-Z])',
  );

  static const _codeMap = {
    'UK': 'GB',
  };

  static String _inferCountry(String tag, String? region) {
    final upper = '$tag $region'.toUpperCase();

    // 1) 中文/全称/城市名匹配（精确子串，按插入顺序检查）。
    //    顺序即优先级，用于消除子串歧义：
    //    「印度尼西亚」须先于「印度」、「内蒙古」先于「蒙古」、
    //    「ROMANIA」先于「OMAN」、美国城市先于「GEORGIA」等。
    const nameMap = {
      // —— 东亚 ——
      '香港': 'HK', 'HONGKONG': 'HK', 'HONG KONG': 'HK', 'HKG': 'HK',
      '澳门': 'MO', 'MACAO': 'MO', 'MACAU': 'MO',
      '台湾': 'TW', 'TAIWAN': 'TW', '台北': 'TW', '新北': 'TW', '台中': 'TW',
      '高雄': 'TW', 'KAOHSIUNG': 'TW', 'TWN': 'TW', '彰化': 'TW',
      '日本': 'JP', 'JAPAN': 'JP', 'TOKYO': 'JP', '大阪': 'JP', '东京': 'JP',
      'OSAKA': 'JP', 'NAGOYA': 'JP', '名古屋': 'JP', 'FUKUOKA': 'JP',
      '福冈': 'JP', 'SAITAMA': 'JP', '埼玉': 'JP', 'JPN': 'JP',
      '韩国': 'KR', 'KOREA': 'KR', 'SEOUL': 'KR', '首尔': 'KR', '釜山': 'KR',
      'BUSAN': 'KR', 'KOR': 'KR',
      '内蒙古': 'CN', // 先于「蒙古」检查，避免境内中转节点被判成蒙古国
      '蒙古': 'MN', 'MONGOLIA': 'MN', 'ULAANBAATAR': 'MN', '乌兰巴托': 'MN',
      // —— 东南亚 ——
      '新加坡': 'SG', 'SINGAPORE': 'SG', 'SGP': 'SG', '狮城': 'SG',
      '越南': 'VN', 'VIETNAM': 'VN', 'HANOI': 'VN', '河内': 'VN',
      'HO CHI MINH': 'VN', 'HOCHIMINH': 'VN', '胡志明': 'VN', 'SAIGON': 'VN',
      '泰国': 'TH', 'THAILAND': 'TH', 'BANGKOK': 'TH', '曼谷': 'TH',
      '菲律宾': 'PH', 'PHILIPPINES': 'PH', 'MANILA': 'PH', '马尼拉': 'PH',
      '马来西亚': 'MY', 'MALAYSIA': 'MY', 'KUALA LUMPUR': 'MY',
      'KUALALUMPUR': 'MY', '吉隆坡': 'MY',
      '印度尼西亚': 'ID', // 先于「印度」检查，否则被误判成 IN
      '印尼': 'ID', 'INDONESIA': 'ID', 'JAKARTA': 'ID', '雅加达': 'ID',
      '柬埔寨': 'KH', 'CAMBODIA': 'KH', 'PHNOM PENH': 'KH', 'PHNOMPENH': 'KH',
      '金边': 'KH',
      '老挝': 'LA', 'LAOS': 'LA', 'VIENTIANE': 'LA', '万象': 'LA',
      '缅甸': 'MM', 'MYANMAR': 'MM', 'YANGON': 'MM', '仰光': 'MM',
      '文莱': 'BN', 'BRUNEI': 'BN',
      // —— 南亚 ——
      '印度': 'IN', 'INDIA': 'IN', 'MUMBAI': 'IN', '孟买': 'IN',
      'CHENNAI': 'IN', '钦奈': 'IN', 'BANGALORE': 'IN', '班加罗尔': 'IN',
      'DELHI': 'IN', '新德里': 'IN',
      '巴基斯坦': 'PK', 'PAKISTAN': 'PK', 'KARACHI': 'PK', '卡拉奇': 'PK',
      'ISLAMABAD': 'PK',
      '孟加拉': 'BD', 'BANGLADESH': 'BD', 'DHAKA': 'BD', '达卡': 'BD',
      '斯里兰卡': 'LK', 'SRI LANKA': 'LK', 'SRILANKA': 'LK', 'COLOMBO': 'LK',
      '科伦坡': 'LK',
      '尼泊尔': 'NP', 'NEPAL': 'NP', 'KATHMANDU': 'NP', '加德满都': 'NP',
      '不丹': 'BT', 'BHUTAN': 'BT',
      '马尔代夫': 'MV', 'MALDIVES': 'MV',
      // —— 中亚 ——
      '哈萨克': 'KZ', 'KAZAKHSTAN': 'KZ', 'ALMATY': 'KZ', '阿拉木图': 'KZ',
      'ASTANA': 'KZ', '阿斯塔纳': 'KZ',
      '乌兹别克': 'UZ', 'UZBEKISTAN': 'UZ', 'TASHKENT': 'UZ', '塔什干': 'UZ',
      '吉尔吉斯': 'KG', 'KYRGYZSTAN': 'KG', 'BISHKEK': 'KG', '比什凯克': 'KG',
      '塔吉克': 'TJ', 'TAJIKISTAN': 'TJ', 'DUSHANBE': 'TJ',
      '土库曼': 'TM', 'TURKMENISTAN': 'TM',
      // —— 中东 ——
      '阿联酋': 'AE', 'DUBAI': 'AE', 'UAE': 'AE', '迪拜': 'AE',
      'ABU DHABI': 'AE', '阿布扎比': 'AE',
      '土耳其': 'TR', 'TURKEY': 'TR', 'ISTANBUL': 'TR', '伊斯坦布尔': 'TR',
      'ANKARA': 'TR',
      '沙特': 'SA', 'SAUDI': 'SA', 'RIYADH': 'SA', '利雅得': 'SA',
      'JEDDAH': 'SA', '吉达': 'SA',
      '卡塔尔': 'QA', 'QATAR': 'QA', 'DOHA': 'QA', '多哈': 'QA',
      '科威特': 'KW', 'KUWAIT': 'KW',
      '巴林': 'BH', 'BAHRAIN': 'BH',
      '约旦': 'JO', 'JORDAN': 'JO', 'AMMAN': 'JO', '安曼': 'JO',
      '以色列': 'IL', 'ISRAEL': 'IL', 'TEL AVIV': 'IL', 'TELAVIV': 'IL',
      '特拉维夫': 'IL',
      '黎巴嫩': 'LB', 'LEBANON': 'LB', 'BEIRUT': 'LB', '贝鲁特': 'LB',
      '伊拉克': 'IQ', 'BAGHDAD': 'IQ', '巴格达': 'IQ',
      '伊朗': 'IR', 'TEHRAN': 'IR', '德黑兰': 'IR',
      '叙利亚': 'SY',
      '也门': 'YE', 'YEMEN': 'YE',
      // —— 欧亚 / 高加索 ——
      '俄罗斯': 'RU', 'RUSSIA': 'RU', 'MOSCOW': 'RU', '莫斯科': 'RU',
      'PETERSBURG': 'RU', '圣彼得堡': 'RU', 'NOVOSIBIRSK': 'RU',
      '新西伯利亚': 'RU', 'KHABAROVSK': 'RU', '伯力': 'RU',
      '乌克兰': 'UA', 'UKRAINE': 'UA', 'KYIV': 'UA', 'KIEV': 'UA',
      '基辅': 'UA',
      '白俄罗斯': 'BY', 'BELARUS': 'BY', 'MINSK': 'BY', '明斯克': 'BY',
      '格鲁吉亚': 'GE', 'TBILISI': 'GE', '第比利斯': 'GE',
      '亚美尼亚': 'AM', 'ARMENIA': 'AM', 'YEREVAN': 'AM', '埃里温': 'AM',
      '阿塞拜疆': 'AZ', 'AZERBAIJAN': 'AZ', 'BAKU': 'AZ', '巴库': 'AZ',
      '摩尔多瓦': 'MD', 'MOLDOVA': 'MD',
      // —— 欧洲 ——
      '英国': 'GB', 'UNITED KINGDOM': 'GB', 'LONDON': 'GB', '伦敦': 'GB',
      'MANCHESTER': 'GB', '曼彻斯特': 'GB',
      '德国': 'DE', 'GERMANY': 'DE', 'FRANKFURT': 'DE', '法兰克福': 'DE',
      'MUNICH': 'DE', '慕尼黑': 'DE', 'BERLIN': 'DE', '柏林': 'DE',
      'DUSSELDORF': 'DE',
      '法国': 'FR', 'FRANCE': 'FR', 'PARIS': 'FR', '巴黎': 'FR',
      'MARSEILLE': 'FR', '马赛': 'FR',
      '荷兰': 'NL', 'NETHERLANDS': 'NL', 'AMSTERDAM': 'NL', '阿姆斯特丹': 'NL',
      '瑞士': 'CH', 'SWITZERLAND': 'CH', 'ZURICH': 'CH', '苏黎世': 'CH',
      'GENEVA': 'CH', '日内瓦': 'CH',
      '爱尔兰': 'IE', 'IRELAND': 'IE', 'DUBLIN': 'IE', '都柏林': 'IE',
      '瑞典': 'SE', 'SWEDEN': 'SE', 'STOCKHOLM': 'SE', '斯德哥尔摩': 'SE',
      '芬兰': 'FI', 'FINLAND': 'FI', 'HELSINKI': 'FI', '赫尔辛基': 'FI',
      '挪威': 'NO', 'NORWAY': 'NO', 'OSLO': 'NO', '奥斯陆': 'NO',
      '丹麦': 'DK', 'DENMARK': 'DK', 'COPENHAGEN': 'DK', '哥本哈根': 'DK',
      '冰岛': 'IS', 'ICELAND': 'IS', 'REYKJAVIK': 'IS', '雷克雅未克': 'IS',
      '波兰': 'PL', 'POLAND': 'PL', 'WARSAW': 'PL', '华沙': 'PL',
      '意大利': 'IT', 'ITALY': 'IT', 'MILAN': 'IT', '米兰': 'IT',
      'ROME': 'IT', '罗马': 'IT',
      '西班牙': 'ES', 'SPAIN': 'ES', 'MADRID': 'ES', '马德里': 'ES',
      'BARCELONA': 'ES', '巴塞罗那': 'ES',
      '葡萄牙': 'PT', 'PORTUGAL': 'PT', 'LISBON': 'PT', '里斯本': 'PT',
      // 「AUSTRIA」在前：'AUS' 是它的子串；澳大利亚不收 'AUS' 缩写键
      // （会误伤 AUSTRIA / 美国 AUSTIN），短码场景由正则 AU 兜底
      '奥地利': 'AT', 'AUSTRIA': 'AT', 'VIENNA': 'AT', '维也纳': 'AT',
      '澳大利亚': 'AU', '澳洲': 'AU', 'AUSTRALIA': 'AU', 'SYDNEY': 'AU',
      '悉尼': 'AU', 'MELBOURNE': 'AU', '墨尔本': 'AU', 'BRISBANE': 'AU',
      '布里斯班': 'AU', 'PERTH': 'AU', '珀斯': 'AU',
      '比利时': 'BE', 'BELGIUM': 'BE', 'BRUSSELS': 'BE', '布鲁塞尔': 'BE',
      '卢森堡': 'LU', 'LUXEMBOURG': 'LU',
      '捷克': 'CZ', 'CZECH': 'CZ', 'PRAGUE': 'CZ', '布拉格': 'CZ',
      '斯洛伐克': 'SK', 'SLOVAKIA': 'SK',
      '匈牙利': 'HU', 'HUNGARY': 'HU', 'BUDAPEST': 'HU', '布达佩斯': 'HU',
      '希腊': 'GR', 'GREECE': 'GR', 'ATHENS': 'GR', '雅典': 'GR',
      // 「ROMANIA」必须先于「OMAN」检查（OMAN 是它的子串）
      '罗马尼亚': 'RO', 'ROMANIA': 'RO', 'BUCHAREST': 'RO', '布加勒斯特': 'RO',
      '阿曼': 'OM', 'OMAN': 'OM', 'MUSCAT': 'OM', '马斯喀特': 'OM',
      '保加利亚': 'BG', 'BULGARIA': 'BG', 'SOFIA': 'BG', '索菲亚': 'BG',
      '塞尔维亚': 'RS', 'SERBIA': 'RS', 'BELGRADE': 'RS', '贝尔格莱德': 'RS',
      '克罗地亚': 'HR', 'CROATIA': 'HR', 'ZAGREB': 'HR', '萨格勒布': 'HR',
      '斯洛文尼亚': 'SI', 'SLOVENIA': 'SI',
      '爱沙尼亚': 'EE', 'ESTONIA': 'EE', 'TALLINN': 'EE', '塔林': 'EE',
      '立陶宛': 'LT', 'LITHUANIA': 'LT', 'VILNIUS': 'LT', '维尔纽斯': 'LT',
      '拉脱维亚': 'LV', 'LATVIA': 'LV', 'RIGA': 'LV', '里加': 'LV',
      '马耳他': 'MT', 'MALTA': 'MT',
      '塞浦路斯': 'CY', 'CYPRUS': 'CY',
      '马其顿': 'MK', 'MACEDONIA': 'MK',
      '阿尔巴尼亚': 'AL', 'ALBANIA': 'AL',
      '波黑': 'BA', 'BOSNIA': 'BA',
      '黑山': 'ME', 'MONTENEGRO': 'ME',
      '直布罗陀': 'GI', 'GIBRALTAR': 'GI',
      '列支敦士登': 'LI', 'LIECHTENSTEIN': 'LI',
      '摩纳哥': 'MC', 'MONACO': 'MC',
      '安道尔': 'AD', 'ANDORRA': 'AD',
      '圣马力诺': 'SM', 'SAN MARINO': 'SM',
      // —— 美国（城市在前：ATLANTA 必须先于 GEORGIA，波士顿先于 MA 码等）——
      '美国': 'US', 'USA': 'US', 'UNITED STATES': 'US',
      'LOS ANGELES': 'US', 'LOSANGELES': 'US', '洛杉矶': 'US',
      'SEATTLE': 'US', '西雅图': 'US', 'SAN JOSE': 'US', 'SANJOSE': 'US',
      '圣何塞': 'US', 'NEW YORK': 'US', 'NEWYORK': 'US', '纽约': 'US',
      '硅谷': 'US', 'SILICON': 'US', 'DALLAS': 'US', '达拉斯': 'US',
      'CHICAGO': 'US', '芝加哥': 'US', 'MIAMI': 'US', '迈阿密': 'US',
      'ATLANTA': 'US', '亚特兰大': 'US', 'BOSTON': 'US', '波士顿': 'US',
      'HOUSTON': 'US', '休斯敦': 'US', 'PHOENIX': 'US', '凤凰城': 'US',
      'SAN FRANCISCO': 'US', 'SANFRANCISCO': 'US', '旧金山': 'US',
      'LAS VEGAS': 'US', 'LASVEGAS': 'US', '拉斯维加斯': 'US',
      'PORTLAND': 'US', 'DENVER': 'US', '丹佛': 'US', 'ASHBURN': 'US',
      'BUFFALO': 'US', 'NEW JERSEY': 'US', 'VIRGINIA': 'US',
      'WASHINGTON': 'US', '华盛顿': 'US', 'OREGON': 'US', 'SALT LAKE': 'US',
      // 「GEORGIA」歧义（美国州 vs 格鲁吉亚国）：城市名已在前面兜底，
      // 走到这里的按格鲁吉亚国处理
      'GEORGIA': 'GE',
      '加拿大': 'CA', 'CANADA': 'CA', 'TORONTO': 'CA', '多伦多': 'CA',
      'VANCOUVER': 'CA', '温哥华': 'CA', 'MONTREAL': 'CA', '蒙特利尔': 'CA',
      '墨西哥': 'MX', 'MEXICO': 'MX',
      '巴拿马': 'PA', 'PANAMA': 'PA',
      '哥斯达黎加': 'CR', 'COSTA RICA': 'CR', 'COSTARICA': 'CR',
      '危地马拉': 'GT', 'GUATEMALA': 'GT',
      '洪都拉斯': 'HN', 'HONDURAS': 'HN',
      '萨尔瓦多': 'SV', 'EL SALVADOR': 'SV', 'ELSALVADOR': 'SV',
      '尼加拉瓜': 'NI', 'NICARAGUA': 'NI',
      '多米尼加': 'DO', 'DOMINICAN': 'DO', 'SANTO DOMINGO': 'DO',
      '波多黎各': 'PR', 'PUERTO RICO': 'PR', 'PUERTORICO': 'PR',
      '圣胡安': 'PR',
      '牙买加': 'JM', 'JAMAICA': 'JM',
      '古巴': 'CU', 'HAVANA': 'CU', '哈瓦那': 'CU',
      '巴哈马': 'BS', 'BAHAMAS': 'BS',
      '伯利兹': 'BZ', 'BELIZE': 'BZ',
      '特立尼达': 'TT', 'TRINIDAD': 'TT',
      '巴巴多斯': 'BB', 'BARBADOS': 'BB',
      '开曼': 'KY', 'CAYMAN': 'KY',
      '百慕大': 'BM', 'BERMUDA': 'BM',
      '英属维尔京': 'VG',
      // —— 南美 ——
      '巴西': 'BR', 'BRAZIL': 'BR', 'SAO PAULO': 'BR', 'SAOPAULO': 'BR',
      '圣保罗': 'BR',
      '智利': 'CL', 'CHILE': 'CL', 'SANTIAGO': 'CL', '圣地亚哥': 'CL',
      '阿根廷': 'AR', 'ARGENTINA': 'AR', 'BUENOS AIRES': 'AR',
      '布宜诺斯艾利斯': 'AR',
      // 「COLOMBIA」注意与斯里兰卡 COLOMBO 拼写不同，可安全共存
      '哥伦比亚': 'CO', 'COLOMBIA': 'CO', 'BOGOTA': 'CO', '波哥大': 'CO',
      '秘鲁': 'PE', 'LIMA': 'PE', '利马': 'PE',
      '委内瑞拉': 'VE', 'VENEZUELA': 'VE', 'CARACAS': 'VE', '加拉加斯': 'VE',
      '厄瓜多尔': 'EC', 'ECUADOR': 'EC', 'QUITO': 'EC', '基多': 'EC',
      '乌拉圭': 'UY', 'URUGUAY': 'UY', 'MONTEVIDEO': 'UY', '蒙得维的亚': 'UY',
      '巴拉圭': 'PY', 'PARAGUAY': 'PY', 'ASUNCION': 'PY', '亚松森': 'PY',
      '玻利维亚': 'BO', 'BOLIVIA': 'BO', 'LA PAZ': 'BO', '拉巴斯': 'BO',
      // —— 大洋洲 ——
      '新西兰': 'NZ', 'NEW ZEALAND': 'NZ', 'NEWZEALAND': 'NZ',
      'AUCKLAND': 'NZ', '奥克兰': 'NZ', 'WELLINGTON': 'NZ', '惠灵顿': 'NZ',
      '斐济': 'FJ', 'FIJI': 'FJ',
      '关岛': 'GU', 'GUAM': 'GU',
      // —— 非洲 ——
      '南非': 'ZA', 'SOUTH AFRICA': 'ZA', 'SOUTHAFRICA': 'ZA',
      'JOHANNESBURG': 'ZA', '约翰内斯堡': 'ZA', 'CAPE TOWN': 'ZA',
      'CAPETOWN': 'ZA', '开普敦': 'ZA',
      '埃及': 'EG', 'EGYPT': 'EG', 'CAIRO': 'EG', '开罗': 'EG',
      '摩洛哥': 'MA', 'MOROCCO': 'MA', 'CASABLANCA': 'MA', '卡萨布兰卡': 'MA',
      '突尼斯': 'TN', 'TUNISIA': 'TN',
      '阿尔及利亚': 'DZ', 'ALGERIA': 'DZ', 'ALGIERS': 'DZ',
      '利比亚': 'LY', 'LIBYA': 'LY',
      '尼日利亚': 'NG', 'NIGERIA': 'NG', 'LAGOS': 'NG', '拉各斯': 'NG',
      '肯尼亚': 'KE', 'KENYA': 'KE', 'NAIROBI': 'KE', '内罗毕': 'KE',
      '埃塞俄比亚': 'ET', 'ETHIOPIA': 'ET',
      '加纳': 'GH', 'GHANA': 'GH', 'ACCRA': 'GH', '阿克拉': 'GH',
      '坦桑尼亚': 'TZ', 'TANZANIA': 'TZ',
      '乌干达': 'UG', 'UGANDA': 'UG', 'KAMPALA': 'UG', '坎帕拉': 'UG',
      '安哥拉': 'AO', 'ANGOLA': 'AO', 'LUANDA': 'AO', '罗安达': 'AO',
      '津巴布韦': 'ZW', 'ZIMBABWE': 'ZW',
      '塞内加尔': 'SN', 'SENEGAL': 'SN', 'DAKAR': 'SN', '达喀尔': 'SN',
      '喀麦隆': 'CM', 'CAMEROON': 'CM',
      '卢旺达': 'RW', 'RWANDA': 'RW', 'KIGALI': 'RW', '基加利': 'RW',
      '毛里求斯': 'MU', 'MAURITIUS': 'MU',
      '塞舌尔': 'SC', 'SEYCHELLES': 'SC',
      // —— 中国（回国节点；置于最后：香港/台湾/澳门等已在前面命中） ——
      '中国': 'CN', '回国': 'CN', 'CHINA': 'CN', '上海': 'CN', '北京': 'CN',
      '深圳': 'CN', '广州': 'CN', '江苏': 'CN', '浙江': 'CN', '徐州': 'CN',
    };
    for (final e in nameMap.entries) {
      if (upper.contains(e.key)) return e.value;
    }

    // 2) 短国家代码匹配。先剔除「NO.1」式编号（NO 会被误判成挪威码）
    final cleaned = upper.replaceAll(RegExp(r'NO\.\s*\d+'), ' ');
    final m = _prefixCodeRe.firstMatch(cleaned);
    if (m != null) {
      final code = m.group(1)!;
      return _codeMap[code] ?? code;
    }

    return 'XX';
  }
}

/// 面板展示性伪节点判定（📢官网 / ⏰到期 / 📱设备 / 💬客服 / 🎯 等，
/// `server` 是 `baidu.com:1234` 这类占位地址）。
///
/// 为什么要有这个判据：这些条目**不是节点**，只是机场用来在客户端列表里
/// 显示公告/客服链接的占位项（真实订阅里就有 3~5 个）。
///
/// 主过滤点在订阅解析阶段（`SubscriptionService._nodesFromYamlMap`），所以它们
/// 正常情况下**根本不会出现在节点列表里**。测速侧（[SpeedTester] / 内核探测）
/// 仍然用同一判据再兜一次，原因是对它们做 TCP 测速会连上**真实的 baidu.com**，
/// 得到一个「很健康的 8ms」，用户会以为捡到超快节点 —— 一旦哪个入口绕过了
/// 订阅解析，这就是一个安静的假阳性。
///
/// 统一口径：**跳过且不给数字**（延迟 -1），而不是给一个假延迟。
bool isPanelPseudoNode(String tag, String server) {
  const markers = ['📢', '⏰', '📱', '💬', '🎯', '🚀', '♻️', '🔯', '🔮', '🛑', '🐟'];
  return markers.any(tag.contains) || server == 'baidu.com';
}
