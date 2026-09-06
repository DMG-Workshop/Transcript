import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../recording/recording_controller.dart';
import '../settings/settings_screen.dart';

/// First run: what "bring your own AI" actually means, and where a recording goes.
///
/// The hard part of onboarding a BYOK app is that the honest explanation — "you need an
/// API key, or a model on your computer, or a model downloaded to the phone" — is
/// exactly the explanation that makes people close the app. The order here is chosen to
/// avoid that: lead with what the app does for you, then with the fact that it works out
/// of the box with nothing to buy, and only then mention keys as the way to get better
/// results. Nobody is asked for a key before they have seen the app do anything.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  /// Called once, after the last page. The caller records that onboarding happened and
  /// swaps this screen out.
  final VoidCallback onDone;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_Page> get _pages => [
        const _Page(
          icon: Icons.mic_none,
          title: 'Record anything worth remembering',
          body:
              'A meeting, a lecture, a walk where you think out loud. Transcript '
              'turns the recording into a summary, decisions and action items you '
              'can work from — with a board and a timeline when the work needs it.',
        ),
        const _Page(
          icon: Icons.quickreply_outlined,
          title: 'Every task points at what was said',
          body:
              'Each item carries the words it came from, so you can check it in one '
              'tap. Anything the app could not trace back to the recording is '
              'flagged rather than quietly presented as fact — and a date nobody '
              'actually said is never invented.',
        ),
        const _Page(
          icon: Icons.key_outlined,
          title: 'You bring the AI',
          body:
              'There is no subscription here and no account to make. Out of the '
              'box the app uses your phone\'s own speech recognition, which is free '
              'and works offline. Connect a service like Claude, OpenAI or Gemini '
              'with your own API key, or a model running on your own computer, when '
              'you want better notes.',
        ),
        _Page(
          icon: Icons.lock_outline,
          title: 'Where your recording goes',
          body: _postureBody,
          detail: PrivacyDisclosure.byId('audio').plainLanguage,
        ),
      ];

  /// Reads the posture the app is about to run with, rather than describing a generic
  /// one, so the promise made at onboarding matches the app the user is about to use.
  String get _postureBody {
    final posture = ref.read(settingsStoreProvider).posture;
    return '${posture.summary}. ${posture.detail}';
  }

  bool get _isLast => _page == _pages.length - 1;

  void _next() {
    if (_isLast) {
      widget.onDone();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pages = _pages;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: widget.onDone,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (index) => setState(() => _page = index),
                children: pages,
              ),
            ),
            Semantics(
              label: 'Page ${_page + 1} of ${pages.length}',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < pages.length; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(_isLast ? 'Start recording' : 'Next'),
                    ),
                  ),
                  if (_isLast) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        widget.onDone();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      },
                      child: const Text('Choose my AI first'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Optional smaller print. Used on the privacy page, where the full disclosure is
  /// worth showing but should not crowd out the one-line version.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Decorative: the heading below says the same thing in words, and a screen
          // reader announcing "lock icon" before it adds nothing.
          ExcludeSemantics(
            child: Icon(icon, size: 48, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineSmall),
          ),
          const SizedBox(height: 14),
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                detail!,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
