import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:global_repository/global_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import '../../controllers/terminal_controller.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/services/password_manager.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/environment_config.dart';
import '../../widgets/diagnostic_dialog.dart';

class SettingsPage extends StatefulWidget {
  final WebViewController dashboardController;
  final WebViewController napCatController;

  const SettingsPage({
    super.key,
    required this.dashboardController,
    required this.napCatController,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _backupDirPath =
      '/storage/emulated/0/Download/NapCatBubble';
  static const String _backupFilePrefix = 'NapCatBubble-backup-';
  static const String _backupFileSuffix = '.tar.gz';

  String _appVersion = '';
  bool _isBatteryOptimizationIgnored = false;

  // 存储从GitHub API获取的原始下载URL
  String? _originalDownloadUrl;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _checkBatteryOptimizationStatus();
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = _displayVersion(packageInfo.version);
    });
  }

  String _displayVersion(String version) {
    return version.split('+').first.replaceAll('-', ' ');
  }

  String _githubProxyUrl(String url) {
    final proxy = EnvironmentConfig.effectiveGithubProxy;
    if (proxy == EnvironmentConfig.directProxy || proxy.trim().isEmpty) {
      return url;
    }
    return '${proxy.replaceFirst(RegExp(r'/+$'), '')}/$url';
  }

  String _currentGithubSourceName() {
    final selected = EnvironmentConfig.githubProxy;
    if (selected == EnvironmentConfig.autoProxy) {
      final resolved = EnvironmentConfig.effectiveGithubProxy;
      return '自动选择（${EnvironmentConfig.labelForProxy(resolved)}）';
    }
    if (selected == EnvironmentConfig.directProxy) return 'GitHub 原始链接';
    return EnvironmentConfig.labelForProxy(selected);
  }

  Future<void> _pickHomeBackground() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;

      Get.find<HomeController>().setHomeBackgroundPath(path);
      Get.snackbar(
        '已更新背景',
        '主页背景图片已生效',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '选择失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  void _clearHomeBackground() {
    Get.find<HomeController>().clearHomeBackgroundPath();
    Get.snackbar(
      '已清除背景',
      '主页已恢复默认背景',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  Widget _buildOpacitySlider({
    required String title,
    required String subtitle,
    required IconData icon,
    required double value,
    required ValueChanged<double> onChanged,
    double max = 0.95,
    int divisions = 19,
  }) {
    final percent = (value * 100).round();
    return ListTile(
      leading: Icon(icon),
      title: Row(
        children: [
          Expanded(child: Text(title)),
          Text('$percent%'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle),
          Slider(
            value: value.clamp(0.0, max).toDouble(),
            min: 0.0,
            max: max,
            divisions: divisions,
            label: '$percent%',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildHomeFontScaleStepper(HomeController controller) {
    final scale = controller.homeFontScale.value;
    final percent = (scale * 100).round();
    const step = 0.05;
    const minScale = 0.25;
    const maxScale = 1.25;
    return ListTile(
      leading: const Icon(Icons.format_size),
      title: Row(
        children: [
          const Expanded(child: Text('主页字体大小')),
          Text('$percent%'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('调整主页卡片、按钮和账号信息文字大小'),
          Row(
            children: [
              IconButton(
                tooltip: '缩小',
                onPressed: scale <= minScale
                    ? null
                    : () => controller.setHomeFontScale(scale - step),
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: Text(
                  '$percent%',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '放大',
                onPressed: scale >= maxScale
                    ? null
                    : () => controller.setHomeFontScale(scale + step),
                icon: const Icon(Icons.add),
              ),
              TextButton(
                onPressed: scale == 1.0
                    ? null
                    : () => controller.setHomeFontScale(1.0),
                child: const Text('默认'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _disposeTextControllersSafely(
    List<TextEditingController> controllers,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
  }

  // 检查电池优化豁免状态
  Future<void> _checkBatteryOptimizationStatus() async {
    if (!Platform.isAndroid) return;

    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      setState(() {
        _isBatteryOptimizationIgnored = status.isGranted;
      });
    } catch (e) {
      Log.e('检查电池优化豁免状态失败: $e', tag: 'NapCat');
    }
  }

  // 请求电池优化豁免
  Future<void> _requestBatteryOptimization() async {
    if (!Platform.isAndroid) return;

    try {
      final status = await Permission.ignoreBatteryOptimizations.status;

      if (status.isGranted) {
        Get.snackbar(
          '已授权',
          '已获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
        return;
      }

      // 请求权限
      final result = await Permission.ignoreBatteryOptimizations.request();

      // 等待对话框关闭后重新检查状态
      await Future.delayed(const Duration(milliseconds: 500));
      await _checkBatteryOptimizationStatus();

      if (result.isGranted) {
        Get.snackbar(
          '授权成功',
          '已获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.snackbar(
          '授权失败',
          '未获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      Log.e('请求电池优化豁免失败: $e', tag: 'NapCat');
      Get.snackbar(
        '请求失败',
        '请求电池优化豁免时发生错误: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
    }
  }

  // 检查更新
  Future<void> _checkForUpdates() async {
    try {
      // 每次检查更新时重置原始URL
      _originalDownloadUrl = null;

      // 显示加载提示
      Get.dialog(
        const Center(child: CircularProgressIndicator()),
        barrierDismissible: false,
      );

      // 获取当前版本
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final apiUrl = '${Config.githubApi}${Config.githubReleasesPath}';
      final apiFallback =
          '${Config.githubApiFallback.replaceFirst(RegExp(r'/+$'), '')}/$apiUrl';
      final selectedProxy = _githubProxyUrl(apiUrl);
      final mirrors = <String>[apiUrl, apiFallback];
      if (!mirrors.contains(selectedProxy)) mirrors.add(selectedProxy);

      Map<String, dynamic>? releaseData;

      for (final mirror in mirrors) {
        try {
          final response = await http.get(
            Uri.parse(mirror),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          ).timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            releaseData = jsonDecode(response.body) as Map<String, dynamic>;
            break;
          }
          Log.w(
            '更新源 $mirror 返回 HTTP ${response.statusCode}',
            tag: 'NapCat',
          );
        } catch (e) {
          Log.w('镜像源 $mirror 请求失败: $e', tag: 'NapCat');
          continue;
        }
      }

      Get.back(); // 关闭加载提示

      if (releaseData == null) {
        Get.snackbar(
          '检查失败',
          '无法连接到更新服务器',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
        );
        return;
      }

      // 解析最新版本号
      final latestVersion =
          (releaseData['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      final releaseNotes = releaseData['body'] as String? ?? '暂无更新说明';

      // 比较版本号
      if (_compareVersions(latestVersion, currentVersion) > 0) {
        // 有新版本，显示更新对话框
        _showUpdateDialog(latestVersion, releaseNotes, releaseData);
      } else {
        Get.snackbar(
          '已是最新版本',
          '当前版本 $currentVersion 已是最新版本',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      Get.back(); // 关闭加载提示
      Log.e('检查更新失败: $e', tag: 'NapCat');
      Get.snackbar(
        '检查失败',
        '检查更新时发生错误: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  // 版本号比较
  int _compareVersions(String v1, String v2) {
    final parts1 = _parseVersion(v1);
    final parts2 = _parseVersion(v2);
    final core1 = parts1.$1;
    final core2 = parts2.$1;

    for (int i = 0; i < 3; i++) {
      final p1 = i < core1.length ? core1[i] : 0;
      final p2 = i < core2.length ? core2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }

    final pre1 = parts1.$2;
    final pre2 = parts2.$2;
    if (pre1.isEmpty && pre2.isEmpty) return 0;
    if (pre1.isEmpty) return 1;
    if (pre2.isEmpty) return -1;

    final length = math.max(pre1.length, pre2.length);
    for (int i = 0; i < length; i++) {
      if (i >= pre1.length) return -1;
      if (i >= pre2.length) return 1;

      final p1 = pre1[i];
      final p2 = pre2[i];
      if (p1 is int && p2 is int) {
        if (p1 != p2) return p1.compareTo(p2);
      } else if (p1 is int) {
        return -1;
      } else if (p2 is int) {
        return 1;
      } else {
        final compared = p1.toString().compareTo(p2.toString());
        if (compared != 0) return compared;
      }
    }
    return 0;
  }

  (List<int>, List<Object>) _parseVersion(String version) {
    final normalized =
        version.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final separator = normalized.indexOf('-');
    final coreText =
        separator < 0 ? normalized : normalized.substring(0, separator);
    final prereleaseText =
        separator < 0 ? '' : normalized.substring(separator + 1);
    final core =
        coreText.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final prerelease = RegExp(r'[A-Za-z]+|\d+')
        .allMatches(prereleaseText.toLowerCase())
        .map<Object>((match) {
      final value = match.group(0)!;
      return int.tryParse(value) ?? value;
    }).toList();
    return (core, prerelease);
  }

  // 显示更新对话框
  void _showUpdateDialog(
      String version, String releaseNotes, Map<String, dynamic> releaseData) {
    Get.dialog(
      Dialog(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Text(
                    '发现新版本 $version',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Get.back(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: MarkdownBody(
                  data: releaseNotes,
                  styleSheet: MarkdownStyleSheet(
                    h1: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    p: const TextStyle(fontSize: 14),
                    listBullet: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Get.back(),
                    child: const Text('关闭'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      Get.back();
                      _showDownloadSourceDialog(releaseData);
                    },
                    child: const Text('去下载'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 显示下载源选择对话框
  void _showDownloadSourceDialog(Map<String, dynamic> releaseData) {
    // 如果还没有保存原始URL，从releaseData中构造
    if (_originalDownloadUrl == null) {
      final assets = releaseData['assets'] as List?;
      final tagName = releaseData['tag_name'] as String?;

      if (tagName == null || assets == null) {
        Get.snackbar(
          '下载失败',
          '未找到版本信息',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 查找APK文件名
      String? apkFileName;
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          apkFileName = name;
          break;
        }
      }

      if (apkFileName == null) {
        Get.snackbar(
          '下载失败',
          '未找到可下载的APK文件',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 直接构造GitHub原始下载链接，避免使用可能被镜像站污染的URL
      _originalDownloadUrl =
          '${Config.githubDownloadBase}/$tagName/$apkFileName';
    }

    final sources = [
      {
        'name': _currentGithubSourceName(),
        'icon': EnvironmentConfig.effectiveGithubProxy ==
                EnvironmentConfig.directProxy
            ? Icons.cloud_download
            : Icons.speed,
        'url': _githubProxyUrl(_originalDownloadUrl!),
        'description': '使用环境管理中选择的 GitHub 加速策略',
      },
    ];

    Get.dialog(
      AlertDialog(
        title: const Text('选择下载源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请选择适合您网络环境的下载源',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ...sources.map((source) {
              return ListTile(
                leading: Icon(source['icon'] as IconData),
                title: Text(source['name'] as String),
                subtitle: source['description'] != null
                    ? Text(
                        source['description'] as String,
                        style: const TextStyle(fontSize: 12),
                      )
                    : null,
                onTap: () async {
                  final url = source['url'] as String;
                  final uri = Uri.parse(url);

                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                    Get.back();
                  } else {
                    Get.snackbar(
                      '打开失败',
                      '无法打开浏览器',
                      snackPosition: SnackPosition.BOTTOM,
                      backgroundColor: Colors.red,
                      colorText: Colors.white,
                    );
                  }
                },
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  // 执行备份操作
  Future<bool> _performBackup({bool showLoadingDialog = false}) async {
    try {
      // 检查并请求存储权限
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          // 如果 MANAGE_EXTERNAL_STORAGE 未授予，尝试传统的存储权限
          var storageStatus = await Permission.storage.status;
          if (!storageStatus.isGranted) {
            storageStatus = await Permission.storage.request();
            if (!storageStatus.isGranted) {
              Get.snackbar(
                '权限不足',
                '需要存储权限才能备份数据',
                snackPosition: SnackPosition.BOTTOM,
                backgroundColor: Colors.orange,
                colorText: Colors.white,
                duration: const Duration(seconds: 3),
              );
              return false;
            }
          }
        }
      }

      // 权限获取成功后，如果需要显示加载对话框
      if (showLoadingDialog) {
        Get.dialog(
          const Center(child: CircularProgressIndicator()),
          barrierDismissible: false,
        );
      }

      // 获取当前时间戳
      final now = DateTime.now();
      final timestamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';

      // 备份文件路径（保存到下载文件夹）
      final backupDir = Directory(_backupDirPath);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final backupFileName = '$_backupFilePrefix$timestamp$_backupFileSuffix';
      final backupPath = '${backupDir.path}/$backupFileName';

      // 使用 tar 命令压缩 data 目录
      final dataPath = '${scripts.ubuntuPath}/root/NapCat';
      final dataDir = Directory(dataPath);

      if (!await dataDir.exists()) {
        Get.snackbar(
          '备份失败',
          'NapCat 数据目录不存在',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return false;
      }

      // 执行备份命令
      final result = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-czf',
        backupPath,
        '-C',
        '${scripts.ubuntuPath}/root/NapCat',
        'data',
      ]);

      if (result.exitCode == 0) {
        final backupFile = File(backupPath);
        final fileSize = await backupFile.length();
        final fileSizeMB = (fileSize / 1024 / 1024).toStringAsFixed(2);

        if (showLoadingDialog) {
          Get.back(); // 关闭加载对话框
        }

        Get.snackbar(
          '备份成功',
          '备份文件: $backupFileName\n大小: ${fileSizeMB}MB',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
        Log.i('备份成功: $backupPath (${fileSizeMB}MB)', tag: 'NapCat');
        return true;
      } else {
        if (showLoadingDialog) {
          Get.back(); // 关闭加载对话框
        }

        Get.snackbar(
          '备份失败',
          '错误: ${result.stderr}',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        Log.e('备份失败: ${result.stderr}', tag: 'NapCat');
        return false;
      }
    } catch (e) {
      if (showLoadingDialog) {
        Get.back(); // 关闭加载对话框
      }

      Get.snackbar(
        '备份失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
      Log.e('备份异常: $e', tag: 'NapCat');
      return false;
    }
  }

  Future<void> _showRestoreBackupDialog() async {
    final backupDir = Directory(_backupDirPath);
    if (!await backupDir.exists()) {
      Get.snackbar(
        '没有备份',
        '未找到泡泡版备份目录：$_backupDirPath',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    final backups = await backupDir
        .list()
        .where((entity) {
          final name = entity.uri.pathSegments.last;
          return entity is File &&
              name.startsWith(_backupFilePrefix) &&
              name.endsWith(_backupFileSuffix);
        })
        .cast<File>()
        .toList();

    backups.sort((a, b) {
      return b.lastModifiedSync().compareTo(a.lastModifiedSync());
    });

    if (backups.isEmpty) {
      Get.snackbar(
        '没有备份',
        '$_backupDirPath 下没有泡泡版备份文件',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    final selected = await Get.dialog<File>(
      AlertDialog(
        title: const Text('选择备份还原'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: backups.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final file = backups[index];
              final stat = file.statSync();
              final sizeMb = (stat.size / 1024 / 1024).toStringAsFixed(2);
              return ListTile(
                title: Text(file.uri.pathSegments.last),
                subtitle: Text('${stat.modified}\n$sizeMb MB'),
                isThreeLine: true,
                onTap: () => Get.back(result: file),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
        ],
      ),
    );

    if (selected == null) return;

    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('确认还原'),
        content: Text(
          '将使用以下备份覆盖当前 NapCat 数据：\n\n'
          '${selected.uri.pathSegments.last}\n\n'
          '还原前会尝试停止 NapCat，还原成功后应用会退出，请重新打开。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('确认还原'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _performRestore(selected);
    }
  }

  Future<void> _performRestore(File backupFile) async {
    Get.dialog(
      const Center(child: CircularProgressIndicator()),
      barrierDismissible: false,
    );

    try {
      if (Get.isRegistered<HomeController>()) {
        final hc = Get.find<HomeController>();
        for (final inst in hc.napCatInstances) {
          final id = inst['id']?.toString();
          if (id != null && id.isNotEmpty) {
            await hc.stopNapCatInstance(id);
          }
        }
      }

      final napCatDir = Directory('${scripts.ubuntuPath}/root/NapCat');
      final dataDir = Directory('${napCatDir.path}/data');
      final tempDataDir = Directory(
        '${napCatDir.path}/data_restore_old_${DateTime.now().millisecondsSinceEpoch}',
      );

      if (!await napCatDir.exists()) {
        await napCatDir.create(recursive: true);
      }

      if (await dataDir.exists()) {
        await dataDir.rename(tempDataDir.path);
      }

      final result = await Process.run('${RuntimeEnvir.binPath}/busybox', [
        'tar',
        '-xzf',
        backupFile.path,
        '-C',
        napCatDir.path,
      ]);

      if (result.exitCode != 0) {
        if (await dataDir.exists()) {
          await dataDir.delete(recursive: true);
        }
        if (await tempDataDir.exists()) {
          await tempDataDir.rename(dataDir.path);
        }
        throw Exception(result.stderr.toString());
      }

      if (await tempDataDir.exists()) {
        await tempDataDir.delete(recursive: true);
      }

      Get.back();
      Get.snackbar(
        '还原成功',
        'NapCat 数据已还原，应用即将退出',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
      await Future.delayed(const Duration(seconds: 2));
      exit(0);
    } catch (e) {
      Get.back();
      Get.snackbar(
        '还原失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
      );
    }
  }

  // 打开文件管理器并导航到 NapCat Ubuntu 文件系统位置
  Future<void> _openFileManager() async {
    try {
      // 使用 DocumentsProvider 的 content URI 打开文件管理器
      // authority: 当前应用包名.documents
      // rootId: ubuntu_root
      final packageName =
          RuntimeEnvir.packageName ?? 'com.astrbot.astrbot_android';
      final contentUri = Uri.parse(
        'content://$packageName.documents/root/ubuntu_root',
      );

      if (await canLaunchUrl(contentUri)) {
        await launchUrl(
          contentUri,
          mode: LaunchMode.externalApplication,
        );

        Get.snackbar(
          '已打开',
          '已在文件管理器中打开 NapCat Ubuntu 文件系统',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        // 如果无法打开，提供备选方案
        Get.dialog(
          AlertDialog(
            title: const Text('打开文件系统'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ubuntu 文件系统已挂载至系统"文件"应用的侧栏，名称为:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text(
                  'NapCat Ubuntu',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '你可以手动打开系统"文件"应用，在侧栏中找到"NapCat Ubuntu"来访问。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                const Text(
                  '或使用 MT 文件管理器等应用，添加以下路径至侧栏:',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  scripts.ubuntuPath,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: scripts.ubuntuPath));
                  Get.back();
                  Get.snackbar(
                    '已复制',
                    '路径已复制到剪贴板',
                    snackPosition: SnackPosition.BOTTOM,
                    duration: const Duration(seconds: 2),
                  );
                },
                child: const Text('复制路径'),
              ),
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Log.e('打开文件管理器失败: $e', tag: 'NapCat');
      Get.snackbar(
        '打开失败',
        '无法打开文件管理器: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            '设置',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.health_and_safety_outlined),
          title: const Text('自诊断'),
          subtitle: const Text('检查环境、进程、连接和 NapCat 配置'),
          onTap: () => showDiagnosticDialog(context, Get.find<HomeController>()),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('软件版本'),
          subtitle: Text(
            _appVersion.isEmpty ? '加载中...' : '$_appVersion（点击检查更新）',
          ),
          onTap: () => _checkForUpdates(),
        ),
        Obx(() {
          final backgroundPath =
              Get.find<HomeController>().homeBackgroundPath.value;
          return ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('主页背景图片'),
            subtitle: Text(backgroundPath.isEmpty ? '使用默认背景' : backgroundPath),
            trailing: backgroundPath.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除背景',
                    onPressed: _clearHomeBackground,
                    icon: const Icon(Icons.close),
                  ),
            onTap: _pickHomeBackground,
          );
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildHomeFontScaleStepper(controller);
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildOpacitySlider(
            title: '卡片透明度',
            subtitle: '调整主页卡片和底部菜单的毛玻璃底色',
            icon: Icons.layers_outlined,
            value: controller.cardGlassOpacity.value,
            onChanged: controller.setCardGlassOpacity,
          );
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildOpacitySlider(
            title: '毛玻璃度',
            subtitle: '调整背景被模糊的强度，越低越清晰',
            icon: Icons.blur_on,
            value: controller.glassBlurAmount.value,
            max: 1.0,
            divisions: 20,
            onChanged: controller.setGlassBlurAmount,
          );
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildOpacitySlider(
            title: '顶部导航透明度',
            subtitle: '调整顶部标题栏和 WebUI/终端标签栏',
            icon: Icons.view_day_outlined,
            value: controller.topNavGlassOpacity.value,
            onChanged: controller.setTopNavGlassOpacity,
          );
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildOpacitySlider(
            title: '设置背景遮罩',
            subtitle: '调整设置页全屏背景遮罩强度',
            icon: Icons.filter_b_and_w_outlined,
            value: controller.statusOverlayOpacity.value,
            onChanged: controller.setStatusOverlayOpacity,
          );
        }),
        Obx(() {
          final controller = Get.find<HomeController>();
          return _buildOpacitySlider(
            title: '终端黑色遮罩',
            subtitle: '调整终端透明背景上的黑色遮罩强度',
            icon: Icons.terminal,
            value: controller.terminalOverlayOpacity.value,
            onChanged: controller.setTerminalOverlayOpacity,
          );
        }),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('更新或重装 NapcatQQ'),
          subtitle: const Text('清除 NapcatQQ 组件并重新安装最新版本'),
          onTap: () async {
            // 显示确认对话框
            final confirm = await Get.dialog<bool>(
              AlertDialog(
                title: const Text('确认重新安装'),
                content: const Text('此操作将删除 NapcatQQ 安装文件（保留配置文件）并重新安装，确定继续吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Get.back(result: false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Get.back(result: true),
                    child: const Text(
                      '确定',
                      style: TextStyle(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            );

            if (confirm == true) {
              try {
                // 删除 launcher.sh 文件，这是安装判断的依据
                final launcherPath = '${scripts.ubuntuPath}/root/launcher.sh';
                final launcherFile = File(launcherPath);
                if (await launcherFile.exists()) {
                  await launcherFile.delete();
                  Log.i('已删除 launcher.sh: $launcherPath', tag: 'NapCat');
                }

                if (context.mounted) {
                  Get.snackbar(
                    '重装成功',
                    '应用将自动退出，请重新启动',
                    snackPosition: SnackPosition.BOTTOM,
                    duration: const Duration(seconds: 2),
                  );

                  // 2秒后自动退出应用
                  Future.delayed(const Duration(seconds: 2), () {
                    exit(0);
                  });
                }
              } catch (e) {
                Log.e('重新安装 NapcatQQ 失败: $e', tag: 'NapCat');
                if (context.mounted) {
                  Get.snackbar(
                    '重新安装失败',
                    e.toString(),
                    snackPosition: SnackPosition.BOTTOM,
                    backgroundColor: Colors.red,
                    colorText: Colors.white,
                  );
                }
              }
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.backup),
          title: const Text('备份 NapCat 数据'),
          subtitle: const Text('备份 NapCat 配置和数据到手机存储'),
          onTap: () async {
            await _performBackup(showLoadingDialog: true);
          },
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('还原 NapCat 数据'),
          subtitle: const Text('从 Download/NapCatBubble 选择备份还原'),
          onTap: _showRestoreBackupDialog,
        ),
        ListTile(
          leading: const Icon(Icons.delete),
          title: const Text('清除 NapCat 数据'),
          subtitle: const Text('清除 NapCat 配置和数据，\n重启时自动从备份恢复或重新初始化'),
          onTap: () async {
            // 显示确认对话框
            final confirmed = await Get.dialog<bool>(
              AlertDialog(
                title: const Text('确认清除数据'),
                content: const Text(
                  '此操作将删除所有 NapCat 数据和配置，\n'
                  '重启后将自动从备份恢复或重新初始化。\n\n'
                  '是否继续？',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Get.back(result: false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Get.back(result: true),
                    child: const Text(
                      '确定',
                      style: TextStyle(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            );

            if (confirmed == true) {
              try {
                final dataPath = '${scripts.ubuntuPath}/root/NapCat';
                final dataDir = Directory(dataPath);

                if (await dataDir.exists()) {
                  await dataDir.delete(recursive: true);
                  Log.i('已清除 NapCat 数据目录: $dataPath', tag: 'NapCat');

                  Get.snackbar(
                    '清除成功',
                    'NapCat 数据已清除，应用即将退出',
                    snackPosition: SnackPosition.BOTTOM,
                    duration: const Duration(seconds: 2),
                  );

                  // 等待提示显示后退出应用
                  await Future.delayed(const Duration(seconds: 2));
                  exit(0);
                } else {
                  Get.snackbar(
                    '提示',
                    '数据目录不存在，无需清除',
                    snackPosition: SnackPosition.BOTTOM,
                    duration: const Duration(seconds: 2),
                  );
                }
              } catch (e) {
                Log.e('清除 NapCat 数据失败: $e', tag: 'NapCat');
                Get.snackbar(
                  '操作失败',
                  '清除数据失败: $e',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 3),
                );
              }
            }
          },
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            '高级设置',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.battery_saver),
          title: const Text('电池优化豁免'),
          subtitle: Text(_isBatteryOptimizationIgnored ? '已授权' : '未授权（点击授权）'),
          trailing: _isBatteryOptimizationIgnored
              ? const Icon(Icons.check_circle, color: Colors.green)
              : const Icon(Icons.warning, color: Colors.orange),
          onTap: () => _requestBatteryOptimization(),
        ),
        ListTile(
          leading: const Icon(Icons.folder),
          title: const Text('文件系统'),
          subtitle: const Text(
            '内置 Ubuntu 文件系统已挂载至 \'文件\'\n可添加至 MT 文件管理器侧栏以快捷访问',
          ),
          onTap: () => _openFileManager(),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('清空本应用 WebView 缓存'),
          subtitle: const Text('只清理泡泡版 WebView 缓存和本应用保存的密码'),
          onTap: () async {
            try {
              await widget.dashboardController.clearCache();
              await widget.napCatController.clearCache();
              await PasswordManager.clearAllPasswords();
              if (context.mounted) {
                Get.snackbar(
                  '成功',
                  'WebView 缓存和密码已清理',
                  snackPosition: SnackPosition.BOTTOM,
                );
              }
            } catch (e) {
              if (context.mounted) {
                Get.snackbar(
                  '清理失败',
                  e.toString(),
                  snackPosition: SnackPosition.BOTTOM,
                  backgroundColor: Colors.red,
                  colorText: Colors.white,
                );
              }
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('隐私政策'),
          subtitle: const Text('查看应用隐私政策'),
          onTap: () async {
            try {
              final privacyContent =
                  await rootBundle.loadString('assets/privacy_policy.md');
              if (context.mounted) {
                Get.dialog(
                  Dialog(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              const Text(
                                '隐私政策',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () => Get.back(),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16.0),
                            child: MarkdownBody(
                              data: privacyContent,
                              styleSheet: MarkdownStyleSheet(
                                h1: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                                h2: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                                h3: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                                p: const TextStyle(fontSize: 14),
                                listBullet: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                Get.snackbar(
                  '加载失败',
                  '无法加载隐私政策: $e',
                  snackPosition: SnackPosition.BOTTOM,
                  backgroundColor: Colors.red,
                  colorText: Colors.white,
                );
              }
            }
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.exit_to_app, color: Colors.red),
          title: const Text(
            '退出应用',
            style: TextStyle(color: Colors.red),
          ),
          subtitle: const Text('退出 NapCat 应用'),
          onTap: () async {
            // 显示确认对话框
            final confirm = await Get.dialog<bool>(
              AlertDialog(
                title: const Text('确认退出'),
                content: const Text('确定要退出应用吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Get.back(result: false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Get.back(result: true),
                    child: const Text(
                      '退出',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            );

            if (confirm == true) {
              Get.snackbar(
                '退出应用',
                '应用即将退出',
                snackPosition: SnackPosition.BOTTOM,
                duration: const Duration(seconds: 2),
              );

              // 2秒后自动退出应用
              Future.delayed(const Duration(seconds: 2), () {
                exit(0);
              });
            }
          },
        ),
      ],
    );
  }
}
