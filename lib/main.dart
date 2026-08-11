import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.white,
    ),
  );
  runApp(const BambuRfidApp());
}

class BambuRfidApp extends StatelessWidget {
  const BambuRfidApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF202020);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BambuRFID',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: ink,
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        fontFamily: 'sans-serif',
        splashFactory: InkRipple.splashFactory,
      ),
      home: const FilamentScreen(),
    );
  }
}

class FilamentScreen extends StatefulWidget {
  const FilamentScreen({super.key});

  @override
  State<FilamentScreen> createState() => _FilamentScreenState();
}

class _FilamentScreenState extends State<FilamentScreen>
    with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _subscription;
  FilamentData? _filament;
  String _statusCode = 'holdNear';
  String? _nativeError;
  bool _busy = false;
  late bool _isChinese;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final deviceLanguage =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    _isChinese = deviceLanguage.toLowerCase().startsWith('zh');

    _loadSavedLanguage();
    _startReader();
  }

  Future<void> _loadSavedLanguage() async {
    try {
      final saved = await NfcBridge.getPreferredLanguage();
      if (!mounted || saved == null) return;
      setState(() => _isChinese = saved == 'zh');
    } catch (_) {
      // Device locale remains the fallback.
    }
  }

  Future<void> _toggleLanguage() async {
    final next = !_isChinese;
    setState(() => _isChinese = next);
    try {
      await NfcBridge.setPreferredLanguage(next ? 'zh' : 'en');
    } catch (_) {
      // A failed preference write must not block the UI switch.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NfcBridge.start().catchError((_) {});
    } else if (state == AppLifecycleState.paused) {
      NfcBridge.stop().catchError((_) {});
    }
  }

  Future<void> _startReader() async {
    await _subscription?.cancel();
    _subscription = NfcBridge.events.listen(
      (event) {
        if (event is! Map) return;
        final map = Map<String, dynamic>.from(event);
        final type = map['event'] as String?;

        if (type == 'reading') {
          if (!mounted) return;
          setState(() {
            _busy = true;
            _nativeError = null;
            _statusCode = 'reading';
          });
          return;
        }

        if (type == 'tag') {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _nativeError = null;
            // Reader mode stays active. Scanning a different spool replaces the
            // displayed data immediately; there is intentionally no scan button.
            _filament = FilamentData.fromMap(map);
            _statusCode = '';
          });
          HapticFeedback.lightImpact();
          return;
        }

        if (type == 'error') {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _statusCode = '${map['errorCode'] ?? 'readFailed'}';
            _nativeError = map['message'] as String?;
          });
        }
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _statusCode = 'initFailed';
          _nativeError = null;
        });
      },
    );

    try {
      final available = await NfcBridge.isAvailable();
      if (!mounted) return;
      if (!available) {
        setState(() => _statusCode = 'noNfc');
        return;
      }

      final enabled = await NfcBridge.isEnabled();
      if (!mounted) return;
      if (!enabled) {
        setState(() => _statusCode = 'enableNfc');
        return;
      }

      await NfcBridge.start();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _statusCode = 'startFailed';
        _nativeError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _statusCode = 'initFailed';
        _nativeError = null;
      });
    }
  }

  Future<void> _openAbout() async {
    try {
      await NfcBridge.stop();
    } catch (_) {}

    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => AboutScreen(isChinese: _isChinese),
      ),
    );

    if (!mounted) return;
    try {
      await NfcBridge.start();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    NfcBridge.stop().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filament = _filament;
    final primary = filament?.primaryColor ?? const Color(0xFFC7C7C7);
    final secondary = filament?.secondaryColor;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The home screen is authored on one fixed logical canvas and then
            // scaled as a whole. Height is the primary scaling axis; width is
            // only used as a safety cap for unusually narrow screens. This
            // keeps the complete UI on one page with no vertical scrolling.
            const designWidth = 360.0;
            const designHeight = 720.0;
            final heightScale = constraints.maxHeight / designHeight;
            final widthScale = constraints.maxWidth / designWidth;
            final rawScale = heightScale < widthScale ? heightScale : widthScale;

            // Always fit the complete 360×720 canvas inside the SafeArea first,
            // then render the entire home UI at 90% of that fitted size. Do not
            // impose a minimum scale: a minimum larger than rawScale can push the
            // bottom rows off-screen on short displays.
            final fittedScale = rawScale > 1.18 ? 1.18 : rawScale;
            final scale = fittedScale * 0.90;
            final scaledWidth = designWidth * scale;
            final scaledHeight = designHeight * scale;

            return ClipRect(
              child: Center(
                child: SizedBox(
                  width: scaledWidth,
                  height: scaledHeight,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: designWidth,
                    maxWidth: designWidth,
                    minHeight: designHeight,
                    maxHeight: designHeight,
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: designWidth,
                        height: designHeight,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 7, 18, 8),
                          child: Column(
                            children: [
                              _TopBar(
                                isChinese: _isChinese,
                                onLanguageTap: _toggleLanguage,
                                onBrandTap: _openAbout,
                              ),
                              const SizedBox(height: 18),
                              SizedBox(
                                height: 300,
                                width: 324,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 150),
                                  switchInCurve: Curves.easeOut,
                                  switchOutCurve: Curves.easeIn,
                                  child: _FilamentHero(
                                    key: ValueKey(
                                      '${filament?.scanSequence}-${filament?.uid}-$primary-$secondary',
                                    ),
                                    primary: primary,
                                    secondary: secondary,
                                    active: filament != null,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 140),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    child: filament == null
                                        ? _IdleInfo(
                                            statusCode: _statusCode,
                                            nativeError: _nativeError,
                                            busy: _busy,
                                            isChinese: _isChinese,
                                          )
                                        : _FilamentInfo(
                                            data: filament,
                                            isChinese: _isChinese,
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.isChinese,
    required this.onLanguageTap,
    required this.onBrandTap,
  });

  final bool isChinese;
  final VoidCallback onLanguageTap;
  final VoidCallback onBrandTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onBrandTap,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/bamburfid_logo.png',
                      width: 30,
                      height: 30,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                    const SizedBox(width: 9),
                    const Text(
                      'BambuRFID',
                      style: TextStyle(
                        fontSize: 20,
                        height: 1,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.55,
                        color: Color(0xFF202020),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          _LanguageToggle(isChinese: isChinese, onTap: onLanguageTap),
        ],
      ),
    );
  }
}

class _LanguageToggle extends StatelessWidget {
  const _LanguageToggle({
    required this.isChinese,
    required this.onTap,
  });

  final bool isChinese;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFFBDBDBD), width: 0.8),
          ),
          child: Text(
            '中 / EN',
            style: TextStyle(
              fontSize: 15,
              height: 1,
              fontWeight: FontWeight.w400,
              color: isChinese
                  ? const Color(0xFF202020)
                  : const Color(0xFF333333),
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _IdleInfo extends StatelessWidget {
  const _IdleInfo({
    required this.statusCode,
    required this.nativeError,
    required this.busy,
    required this.isChinese,
  });

  final String statusCode;
  final String? nativeError;
  final bool busy;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    final status = _localizedStatus(
      statusCode,
      isChinese: isChinese,
      nativeFallback: nativeError,
    );

    return Column(
      key: ValueKey('idle-$statusCode-$isChinese'),
      children: [
        Text(
          status,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            height: 1.15,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.7,
            color: Color(0xFF242424),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          busy
              ? _tr(isChinese, '保持线盘不动', 'Keep the spool still')
              : _tr(
                  isChinese,
                  '扫描到新线盘后会直接切换',
                  'Switches automatically when a new spool is detected',
                ),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w400,
            color: Color(0xFF8A8A8A),
          ),
        ),
      ],
    );
  }
}

class _FilamentInfo extends StatelessWidget {
  const _FilamentInfo({
    required this.data,
    required this.isChinese,
  });

  final FilamentData data;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    final title = data.detailedType.isNotEmpty
        ? data.detailedType
        : (data.filamentType.isNotEmpty ? data.filamentType : 'Bambu Filament');

    final weight = data.spoolWeightG > 0 ? '${data.spoolWeightG} g' : '—';
    final metaText = '$weight  ·  ${data.productionDateLabel}';
    final colorName = _localizedColorName(data, isChinese);
    final colorText = data.secondaryColor == null
        ? '$colorName  ·  ${data.primaryHexLabel}'
        : '$colorName  ·  ${data.primaryHexLabel} / ${data.secondaryHexLabel}';
    final dryingText = data.dryingTempC > 0 || data.dryingTimeH > 0
        ? '${data.dryingTempC > 0 ? '${data.dryingTempC} °C' : '—'}  ·  '
            '${data.dryingTimeH > 0 ? '${data.dryingTimeH} h' : '—'}'
        : '—';

    return Column(
      key: ValueKey('${data.scanSequence}-${data.uid}-$isChinese'),
      children: [
        SizedBox(
          height: 36,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              maxLines: 1,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30,
                height: 1.08,
                fontWeight: FontWeight.w500,
                letterSpacing: -1.05,
                color: Color(0xFF242424),
              ),
            ),
          ),
        ),
        const SizedBox(height: 11),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 330),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              metaText,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 14,
                height: 1.2,
                fontWeight: FontWeight.w400,
                color: Color(0xFF898989),
                letterSpacing: 0.05,
              ),
            ),
          ),
        ),
        const SizedBox(height: 25),
        _CenteredIntrinsicInfoList(
          children: [
            _InfoLine(
              leading: _ColorDot(
                primary: data.primaryColor,
                secondary: data.secondaryColor,
              ),
              text: colorText,
            ),
            _InfoLine(
              leading: const _DiameterIcon(),
              text: data.diameterMm > 0
                  ? _cleanNumber(data.diameterMm, suffix: ' mm')
                  : '—',
            ),
            _InfoLine(
              leading: const Icon(
                Icons.thermostat_outlined,
                size: 25,
                color: Color(0xFF252525),
              ),
              text: data.minHotendC > 0 || data.maxHotendC > 0
                  ? '${data.minHotendC}–${data.maxHotendC} °C'
                  : '—',
            ),
            _InfoLine(
              leading: const Icon(
                Icons.waves_rounded,
                size: 24,
                color: Color(0xFF252525),
              ),
              text: dryingText,
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }
}

class _CenteredIntrinsicInfoList extends StatelessWidget {
  const _CenteredIntrinsicInfoList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // IntrinsicWidth makes the group exactly as wide as its longest content row.
    // Because the Column stretches to that intrinsic width, every divider gets
    // that same length. The whole group is then centered as a single block while
    // all row content remains left-aligned.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 324),
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.leading,
    required this.text,
    this.showDivider = true,
  });

  final Widget leading;
  final String text;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 30,
                child: Align(alignment: Alignment.centerLeft, child: leading),
              ),
              const SizedBox(width: 16),
              Text(
                text,
                maxLines: 1,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.1,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.15,
                  color: Color(0xFF242424),
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(
            height: 1,
            thickness: 0.7,
            color: Color(0xFFDADADA),
          ),
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.primary, required this.secondary});

  final Color primary;
  final Color? secondary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 19,
      height: 19,
      decoration: BoxDecoration(
        color: secondary == null ? primary : null,
        gradient: secondary == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [primary, secondary!],
              ),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x18000000), width: 0.7),
      ),
    );
  }
}

class _DiameterIcon extends StatelessWidget {
  const _DiameterIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 26,
      height: 26,
      child: CustomPaint(painter: _DiameterIconPainter()),
    );
  }
}

class _DiameterIconPainter extends CustomPainter {
  const _DiameterIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF252525)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.55
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.34;
    canvas.drawCircle(center, radius, paint);
    canvas.drawLine(
      Offset(size.width * 0.19, size.height * 0.81),
      Offset(size.width * 0.81, size.height * 0.19),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FilamentHero extends StatelessWidget {
  const _FilamentHero({
    super.key,
    required this.primary,
    required this.secondary,
    required this.active,
  });

  final Color primary;
  final Color? secondary;
  final bool active;

  static const _neutral = Color(0xFFB9B9B9);

  @override
  Widget build(BuildContext context) {
    final first = active ? primary : _neutral;
    final second = active ? secondary : null;

    final tint = second == null
        ? LinearGradient(colors: [first, first])
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [first, second],
          );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 370, maxHeight: 370),
      child: FractionallySizedBox(
        widthFactor: 0.96,
        child: AspectRatio(
          aspectRatio: 1,
          child: Opacity(
            opacity: active ? 1 : 0.52,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  'assets/spool_base.png',
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  gaplessPlayback: true,
                ),
                ShaderMask(
                  shaderCallback: (bounds) => tint.createShader(bounds),
                  blendMode: BlendMode.modulate,
                  child: Image.asset(
                    'assets/spool_color_luma.png',
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.isChinese});

  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        icon: const Icon(Icons.arrow_back, size: 22),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _tr(isChinese, '关于 BambuRFID', 'About BambuRFID'),
                        style: const TextStyle(
                          fontSize: 20,
                          height: 1,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.5,
                          color: Color(0xFF202020),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 34),
                Center(
                  child: Column(
                    children: [
                      Image.asset(
                        'assets/bamburfid_logo.png',
                        width: 64,
                        height: 64,
                        filterQuality: FilterQuality.high,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'BambuRFID',
                        style: TextStyle(
                          fontSize: 27,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.8,
                          color: Color(0xFF202020),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'v1.6.2',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF8A8A8A),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _tr(
                          isChinese,
                          '极简的 Bambu RFID 耗材读取器',
                          'A minimal Bambu RFID filament reader',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 38),
                _AboutSection(
                  title: _tr(isChinese, '项目简介', 'Project'),
                  child: Text(
                    _tr(
                      isChinese,
                      'BambuRFID 使用 Android NFC 直接读取兼容的 Bambu Lab 耗材 RFID 标签，并显示材料、颜色、重量、生产日期、直径、喷嘴温度和烘干参数。识别到新的线盘后会自动切换当前信息。',
                      'BambuRFID reads compatible Bambu Lab filament RFID tags directly with Android NFC and displays material, color, weight, production date, diameter, nozzle temperature, and drying parameters. A newly detected spool replaces the current result automatically.',
                    ),
                    style: _aboutBodyStyle,
                  ),
                ),
                _AboutSection(
                  title: _tr(isChinese, '使用的技术', 'Technology'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AboutItem(
                        title: 'Flutter',
                        detail: _tr(
                          isChinese,
                          '应用界面与状态管理；Flutter SDK 采用 BSD 3-Clause 许可。',
                          'Application UI and state management; the Flutter SDK is distributed under the BSD 3-Clause license.',
                        ),
                      ),
                      _AboutItem(
                        title: 'Android NFC / MifareClassic',
                        detail: _tr(
                          isChinese,
                          '使用 Android 平台 NFC API 与 MIFARE Classic 扇区认证/读取能力。',
                          'Uses Android platform NFC APIs and MIFARE Classic sector authentication/read support.',
                        ),
                      ),
                      _AboutItem(
                        title: 'HKDF-SHA256',
                        detail: _tr(
                          isChinese,
                          '标签密钥派生实现参考公开的 Bambu RFID 研究资料。',
                          'Tag key derivation follows publicly documented Bambu RFID research.',
                        ),
                        last: true,
                      ),
                    ],
                  ),
                ),
                _AboutSection(
                  title: _tr(isChinese, '研究与参考', 'Research & references'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AboutReference(
                        isChinese: isChinese,
                        name: 'queengooborg/Bambu-Lab-RFID-Tag-Guide',
                        roleZh: 'RFID 数据结构、读取流程与密钥派生研究参考。',
                        roleEn: 'Reference for RFID data layout, reading flow, and key derivation research.',
                        license: 'Upstream repository terms',
                      ),
                      _AboutReference(
                        isChinese: isChinese,
                        name: 'queengooborg/Bambu-Lab-RFID-Library',
                        roleZh: 'RFID 标签样本数据与字段验证参考。',
                        roleEn: 'Reference data for RFID tag samples and field verification.',
                        license: 'GPL-3.0',
                        last: true,
                      ),

                    ],
                  ),
                ),
                _AboutSection(
                  title: _tr(isChinese, '项目仓库', 'Project repository'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SelectableText(
                        'https://github.com/5Breeze/BambuRFID',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF303030),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tr(
                          isChinese,
                          'BambuRFID 是完全开源的非商业项目，不以盈利为目的，不涉及任何商业利益，也不参与商业活动。',
                          'BambuRFID is a fully open-source, non-commercial project. It is not operated for profit, has no commercial interests, and does not participate in commercial activities.',
                        ),
                        style: _aboutBodyStyle,
                      ),
                    ],
                  ),
                ),
                _AboutSection(
                  title: _tr(isChinese, '版权与许可', 'Copyright & license'),
                  child: Text(
                    _tr(
                      isChinese,
                      'BambuRFID 项目代码按 GNU GPL v3.0 发布，完整许可见项目根目录 LICENSE。第三方项目、数据与 SDK 分别受其各自许可条款约束。\n\n“Bambu Lab”及相关商标归其各自权利人所有。本项目为独立社区工具，与 Bambu Lab 无隶属、授权或背书关系。',
                      'BambuRFID project code is distributed under the GNU GPL v3.0; see LICENSE in the project root for the complete terms. Third-party projects, data, and SDKs remain subject to their respective licenses.\n\n“Bambu Lab” and related marks belong to their respective owners. This is an independent community tool and is not affiliated with, authorized by, or endorsed by Bambu Lab.',
                    ),
                    style: _aboutBodyStyle,
                  ),
                ),
                _AboutSection(
                  title: _tr(isChinese, '无担保', 'No warranty'),
                  last: true,
                  child: Text(
                    _tr(
                      isChinese,
                      '本软件按现状提供，不附带任何明示或默示担保。不同 Android 设备的 NFC 芯片对 MIFARE Classic 的支持情况可能不同。',
                      'This software is provided as-is, without warranty of any kind. MIFARE Classic support varies between Android NFC chipsets.',
                    ),
                    style: _aboutBodyStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _aboutBodyStyle = TextStyle(
  fontSize: 15,
  height: 1.62,
  fontWeight: FontWeight.w400,
  color: Color(0xFF3C3C3C),
);

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.title,
    required this.child,
    this.last = false,
  });

  final String title;
  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            height: 1.15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
            color: Color(0xFF202020),
          ),
        ),
        const SizedBox(height: 13),
        child,
        if (!last) ...[
          const SizedBox(height: 27),
          const Divider(height: 1, thickness: 0.7, color: Color(0xFFDADADA)),
          const SizedBox(height: 27),
        ],
      ],
    );
  }
}

class _AboutItem extends StatelessWidget {
  const _AboutItem({
    required this.title,
    required this.detail,
    this.last = false,
  });

  final String title;
  final String detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF252525),
            ),
          ),
          const SizedBox(height: 4),
          Text(detail, style: _aboutBodyStyle.copyWith(fontSize: 14)),
        ],
      ),
    );
  }
}

class _AboutReference extends StatelessWidget {
  const _AboutReference({
    required this.isChinese,
    required this.name,
    required this.roleZh,
    required this.roleEn,
    required this.license,
    this.last = false,
  });

  final bool isChinese;
  final String name;
  final String roleZh;
  final String roleEn;
  final String license;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            name,
            style: const TextStyle(
              fontSize: 14,
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: Color(0xFF252525),
            ),
          ),
          const SizedBox(height: 4),
          Text(isChinese ? roleZh : roleEn, style: _aboutBodyStyle.copyWith(fontSize: 14)),
          const SizedBox(height: 3),
          Text(
            '${_tr(isChinese, '许可', 'License')}: $license',
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: Color(0xFF7A7A7A),
            ),
          ),
        ],
      ),
    );
  }
}

class FilamentData {
  const FilamentData({
    required this.scanSequence,
    required this.uid,
    required this.filamentType,
    required this.detailedType,
    required this.materialId,
    required this.variantId,
    required this.colorHex,
    required this.secondaryColorHex,
    required this.spoolWeightG,
    required this.diameterMm,
    required this.minHotendC,
    required this.maxHotendC,
    required this.bedTempC,
    required this.dryingTempC,
    required this.dryingTimeH,
    required this.productionDateRaw,
  });

  factory FilamentData.fromMap(Map<String, dynamic> map) {
    return FilamentData(
      scanSequence: _asInt(map['scanSequence']),
      uid: '${map['uid'] ?? ''}',
      filamentType: '${map['filamentType'] ?? ''}',
      detailedType: '${map['detailedType'] ?? ''}',
      materialId: '${map['materialId'] ?? ''}',
      variantId: '${map['variantId'] ?? ''}',
      colorHex: '${map['colorHex'] ?? '#A8A8A8'}',
      secondaryColorHex: map['secondaryColorHex'] as String?,
      spoolWeightG: _asInt(map['spoolWeightG']),
      diameterMm: _asDouble(map['diameterMm']),
      minHotendC: _asInt(map['minHotendC']),
      maxHotendC: _asInt(map['maxHotendC']),
      bedTempC: _asInt(map['bedTempC']),
      dryingTempC: _asInt(map['dryingTempC']),
      dryingTimeH: _asInt(map['dryingTimeH']),
      productionDateRaw: '${map['productionDateRaw'] ?? ''}',
    );
  }

  final int scanSequence;
  final String uid;
  final String filamentType;
  final String detailedType;
  final String materialId;
  final String variantId;
  final String colorHex;
  final String? secondaryColorHex;
  final int spoolWeightG;
  final double diameterMm;
  final int minHotendC;
  final int maxHotendC;
  final int bedTempC;
  final int dryingTempC;
  final int dryingTimeH;
  final String productionDateRaw;

  Color get primaryColor => _colorFromHex(colorHex);
  Color? get secondaryColor => secondaryColorHex == null
      ? null
      : _colorFromHex(secondaryColorHex!);

  String get primaryHexLabel => _normalizeHex(colorHex);
  String get secondaryHexLabel => _normalizeHex(secondaryColorHex ?? '');
  String get productionDateLabel => _formatProductionDate(productionDateRaw);
}

class NfcBridge {
  static const MethodChannel _methods = MethodChannel('bambu_rfid/nfc');
  static const EventChannel _events = EventChannel('bambu_rfid/nfc_events');

  static Stream<dynamic> get events => _events.receiveBroadcastStream();

  static Future<bool> isAvailable() async =>
      (await _methods.invokeMethod<bool>('isAvailable')) ?? false;

  static Future<bool> isEnabled() async =>
      (await _methods.invokeMethod<bool>('isEnabled')) ?? false;

  static Future<void> start() => _methods.invokeMethod<void>('start');

  static Future<void> stop() => _methods.invokeMethod<void>('stop');

  static Future<String?> getPreferredLanguage() =>
      _methods.invokeMethod<String>('getPreferredLanguage');

  static Future<void> setPreferredLanguage(String language) =>
      _methods.invokeMethod<void>(
        'setPreferredLanguage',
        <String, Object?>{'language': language},
      );
}

String _tr(bool isChinese, String zh, String en) => isChinese ? zh : en;

String _localizedStatus(
  String code, {
  required bool isChinese,
  String? nativeFallback,
}) {
  switch (code) {
    case 'reading':
      return _tr(isChinese, '正在读取', 'Reading');
    case 'noNfc':
      return _tr(isChinese, '此设备不支持 NFC', 'NFC is not supported');
    case 'enableNfc':
      return _tr(isChinese, '请先开启 NFC', 'Please enable NFC');
    case 'initFailed':
      return _tr(isChinese, 'NFC 初始化失败', 'NFC initialization failed');
    case 'startFailed':
      return _tr(isChinese, '无法启动 NFC', 'Unable to start NFC');
    case 'mifareUnsupported':
      return _tr(
        isChinese,
        '此手机不支持 MIFARE Classic',
        'MIFARE Classic is not supported',
      );
    case 'unexpectedUid':
      return _tr(
        isChinese,
        '这不是标准 Bambu Lab RFID',
        'This is not a standard Bambu Lab RFID tag',
      );
    case 'authFailed':
      return _tr(isChinese, 'RFID 认证失败', 'RFID authentication failed');
    case 'missingBlock':
      return _tr(isChinese, 'RFID 数据不完整', 'RFID data is incomplete');
    case 'readFailed':
      return _tr(isChinese, '无法读取此 RFID', 'Unable to read this RFID tag');
    case 'holdNear':
    default:
      if (!isChinese && nativeFallback != null && nativeFallback.isNotEmpty) {
        return 'Unable to read this RFID tag';
      }
      return _tr(isChinese, '将手机贴近线盘 RFID', 'Hold near the spool RFID');
  }
}

String _localizedColorName(FilamentData data, bool isChinese) {
  if (data.secondaryColor != null) {
    return _tr(isChinese, '双色', 'Multicolor');
  }

  final hsv = HSVColor.fromColor(data.primaryColor);
  final hue = hsv.hue;
  final saturation = hsv.saturation;
  final value = hsv.value;

  if (value < 0.18) return _tr(isChinese, '黑色', 'Black');
  if (saturation < 0.10 && value > 0.88) return _tr(isChinese, '白色', 'White');
  if (saturation < 0.14) return _tr(isChinese, '灰色', 'Gray');
  if (hue < 15 || hue >= 345) return _tr(isChinese, '红色', 'Red');
  if (hue < 45) return _tr(isChinese, '橙色', 'Orange');
  if (hue < 70) return _tr(isChinese, '黄色', 'Yellow');
  if (hue < 165) return _tr(isChinese, '绿色', 'Green');
  if (hue < 195) return _tr(isChinese, '青色', 'Cyan');
  if (hue < 255) return _tr(isChinese, '蓝色', 'Blue');
  if (hue < 300) return _tr(isChinese, '紫色', 'Purple');
  if (hue < 345) return _tr(isChinese, '粉色', 'Pink');
  return _tr(isChinese, '彩色', 'Color');
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse('$value') ?? 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}

String _cleanNumber(double value, {String suffix = ''}) {
  if (value == value.roundToDouble()) return '${value.toInt()}$suffix';
  final cleaned = value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$cleaned$suffix';
}

String _formatProductionDate(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '—';

  final bambu = RegExp(r'^(\d{4})_(\d{2})_(\d{2})').firstMatch(raw);
  if (bambu != null) {
    return '${bambu.group(1)}-${bambu.group(2)}-${bambu.group(3)}';
  }

  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (iso != null) {
    return '${iso.group(1)}-${iso.group(2)}-${iso.group(3)}';
  }

  return raw;
}

String _normalizeHex(String value) {
  final raw = value.replaceAll('#', '').trim().toUpperCase();
  if (raw.length < 6) return '#------';
  return '#${raw.substring(0, 6)}';
}

Color _colorFromHex(String value) {
  final normalized = _normalizeHex(value);
  if (!normalized.startsWith('#') || normalized.contains('-')) {
    return const Color(0xFFA8A8A8);
  }

  final parsed = int.tryParse('FF${normalized.substring(1)}', radix: 16);
  return Color(parsed ?? 0xFFA8A8A8);
}
