#!/usr/bin/env ruby
# frozen_string_literal: true

# 为 mbox 的 iOS 工程创建 / 修复 PacketTunnel 扩展 target。
#
# 为什么用脚本而不是手点 Xcode：pbxproj 是结构化文件，脚本化后
# 可重复执行、可 review、CI 与本地一致（幂等：重复运行会先移除旧 target）。
#
# 用法： ruby tool/ios_setup_tunnel_target.rb
# 前置： ios/Libbox.xcframework 已就位（bash tool/fetch_singbox_ios.sh）
require 'xcodeproj'

PROJECT = 'ios/Runner.xcodeproj'
TARGET_NAME = 'PacketTunnel'
BUNDLE_ID = 'top.mbox.app.tunnel'
DEPLOYMENT_TARGET = '14.0'
FRAMEWORK = 'Libbox.xcframework'

unless File.exist?(PROJECT)
  abort "✗ 未找到 #{PROJECT}（先执行 flutter create --platforms=ios .）"
end

project = Xcodeproj::Project.open(PROJECT)
runner = project.targets.find { |t| t.name == 'Runner' }
abort '✗ 未找到 Runner target' unless runner

# ---- 幂等：移除已存在的扩展 target（含各 target 上指向它的依赖与嵌入引用）----
# 注意顺序：必须先把「别处对它的引用」清干净再删 target，否则残留的
# PBXTargetDependency.target 变成 nil，后续 add_dependency 会抛
# `undefined method 'uuid' for nil`（脚本就不再可重复执行）。
project.targets.select { |t| t.name == TARGET_NAME }.each do |old|
  project.targets.each do |other|
    other.dependencies.select { |d| d.target.nil? || d.target == old }.each(&:remove_from_project)
    other.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.select do |bf|
        ref = bf.file_ref
        ref && (ref.path.to_s.end_with?("#{TARGET_NAME}.appex") || ref == old.product_reference)
      end.each(&:remove_from_project)
    end
  end
  old.product_reference&.remove_from_project
  old.remove_from_project
  puts "· 移除旧的 #{TARGET_NAME} target"
end

# ---- 创建 app extension target ----
target = project.new_target(:app_extension, TARGET_NAME, :ios, DEPLOYMENT_TARGET)

# ---- 源码 ----
group = project.main_group.find_subpath(TARGET_NAME, true)
group.set_source_tree('<group>')
group.set_path(TARGET_NAME)
src = group.new_file('PacketTunnelProvider.swift')
# sing-box 内核封装（Swift 编排 + ObjC 平台接口）
engine_src = group.new_file('LibboxEngine.swift')
platform_h = group.new_file('LibboxPlatform.h')
platform_m = group.new_file('LibboxPlatform.m')
bridge_h = group.new_file('PacketTunnel-Bridging-Header.h')
target.add_file_references([src, engine_src, platform_m])
target.build_configurations.each do |c|
  c.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = "#{TARGET_NAME}/PacketTunnel-Bridging-Header.h"
end

# ---- 构建配置 ----
target.build_configurations.each do |config|
  bs = config.build_settings
  bs['INFOPLIST_FILE'] = "#{TARGET_NAME}/Info.plist"
  bs['CODE_SIGN_ENTITLEMENTS'] = "#{TARGET_NAME}/#{TARGET_NAME}.entitlements"
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  bs['SWIFT_VERSION'] = '5.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['SKIP_INSTALL'] = 'YES'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  bs['CLANG_ENABLE_MODULES'] = 'YES'
  bs['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  # gomobile 产出的静态框架是 Objective-C++，需要 libc++；DNS 解析需要 libresolv
  bs['OTHER_LDFLAGS'] = '$(inherited) -lc++ -lresolv'
end

# ---- 链接 sing-box（gomobile 静态 xcframework）----
if File.exist?("ios/#{FRAMEWORK}")
  fw_ref = project.main_group.files.find { |f| f.path == FRAMEWORK } ||
           project.main_group.new_file(FRAMEWORK)
  fw_ref.last_known_file_type = 'wrapper.xcframework'
  target.frameworks_build_phase.add_file_reference(fw_ref) unless
    target.frameworks_build_phase.files_references.include?(fw_ref)
  puts "· 已链接 #{FRAMEWORK}"
else
  warn "⚠ 未找到 ios/#{FRAMEWORK}：扩展会以「未包含内核」的错误路径编译。" \
       '先运行 bash tool/fetch_singbox_ios.sh'
end

# ---- 把 sing-box 分流规则集作为扩展的**资源**打进 appex ----
# 为什么不用 Run Script：脚本阶段没有输出声明时，Xcode 认为它可能改到产物的
# 任何地方；而这个 appex 又被 Runner 的 Embed App Extensions 阶段嵌入 →
# 直接报 "Cycle inside Runner; building could produce unreliable results"。
# 声明为资源（PBXResourcesBuildPhase）则由 Xcode 正常排序，不会有环。
# 规则集由 CI/本地构建前下载（assets/rules/*.srs），仓库不提交（见 .gitignore）。
geo_group = project.main_group.find_subpath('GeoData', true)
geo_group.set_source_tree('<group>')
geo_group.set_path('../assets/rules')
GEO_FILES = %w[geosite-cn.srs geoip-cn.srs].freeze
GEO_FILES.each do |name|
  ref = geo_group.files.find { |f| f.path == name } || geo_group.new_file(name)
  unless target.resources_build_phase.files_references.include?(ref)
    target.resources_build_phase.add_file_reference(ref)
    puts "· 规则集已加入扩展 bundle: #{name}"
  end
end
warn '⚠ 未找到 assets/rules/*.srs（iOS 构建会失败）。先运行 bash tool/fetch_ruleset.sh' unless
  GEO_FILES.all? { |n| File.exist?("assets/rules/#{n}") }

# ---- Runner 依赖 + 嵌入 PlugIns ----
runner.add_dependency(target) unless runner.dependencies.any? { |d| d.target == target }
embed = runner.build_phases.find do |p|
  p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
    p.name == 'Embed App Extensions'
end
if embed.nil?
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
end
embed.add_file_reference(target.product_reference) unless
  embed.files_references.include?(target.product_reference)
embed.files.find { |f| f.file_ref == target.product_reference }
     &.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# ---- 把「嵌入扩展」排到 Flutter 的脚本阶段之前 ----
# Flutter 的 Thin Binary / Run Script 是本工程的收尾阶段；Embed App Extensions
# 若落在它们之后，Xcode 会认为「脚本可能改动随后被嵌入的产物」从而报
# "Cycle inside Runner"。标准做法是把嵌入阶段放在脚本之前。
scripts = runner.build_phases.select do |p|
  p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
end
if scripts.any?
  first_script_idx = runner.build_phases.index(scripts.first)
  if runner.build_phases.index(embed) > first_script_idx
    runner.build_phases.delete(embed)
    runner.build_phases.insert(first_script_idx, embed)
    puts '· 已把 Embed App Extensions 移到脚本阶段之前（消除构建环）'
  end
end

# ---- Runner 签名 entitlements ----
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# ---- 确保 Runner 侧新增的 Swift 文件进了编译源 ----
# flutter create 生成的 target 只引用模板自带文件；后加的 VpnCorePlugin.swift
# 必须显式加入编译源，否则 AppDelegate 里注册它时编译报
# "Cannot find 'VpnCorePlugin' in scope"（只在编 Runner 时才暴露，
# 单编扩展 target 不会发现）。
runner_group = project.main_group.find_subpath('Runner', true)
Dir.glob('ios/Runner/*.swift').map { |f| File.basename(f) }.sort.each do |name|
  ref = runner_group.files.find { |f| f.path == name || f.display_name == name } ||
        runner_group.new_file(name)
  next if runner.source_build_phase.files_references.include?(ref)

  runner.source_build_phase.add_file_reference(ref)
  puts "· 已把 Runner/#{name} 加入编译源"
end

# Runner 需要知道扩展的 bundle id（App 侧用它筛选 VPN 配置）
runner.build_configurations.each do |config|
  config.build_settings['MBOX_TUNNEL_BUNDLE_ID'] = BUNDLE_ID
end

project.save
puts "✓ 已生成 #{TARGET_NAME} target（bundle id: #{BUNDLE_ID}）"
