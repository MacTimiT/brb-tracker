import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'github_publisher.dart';

const _storage = FlutterSecureStorage();

Future<void> showPublishingSettings(BuildContext context) async {
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PublishingSettings()));
}

Future<void> publishReport(
  BuildContext context,
  Map<String, dynamic> report,
) async {
  final token = await _storage.read(key: 'github_token');
  final owner = await _storage.read(key: 'github_owner') ?? 'MacTimiT';
  final repo = await _storage.read(key: 'github_repo') ?? 'brb-tracker';
  if (!context.mounted) return;
  if (token == null || token.isEmpty) {
    await showPublishingSettings(context);
    return;
  }
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Publish this report?'),
      content: Text(
        'Upload ${(report['breaks'] as List).length} breaks and their transcript evidence to $owner/$repo. The dashboard will rebuild automatically. Review the suggested reasons first. Other real VOD reports will be kept; sample data will be removed.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Publish'),
        ),
      ],
    ),
  );
  if (answer != true || !context.mounted) return;
  final publisher = GitHubPublisher();
  try {
    final commit = await publisher.publish(
      token: token,
      owner: owner,
      repo: repo,
      report: report,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Report uploaded. GitHub Pages is rebuilding; allow a minute, then refresh the dashboard.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Commit',
          onPressed: () => launchUrl(
            Uri.parse(commit),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 10)),
      );
    }
  } finally {
    publisher.close();
  }
}

class PublishingSettings extends StatefulWidget {
  const PublishingSettings({super.key});
  @override
  State<PublishingSettings> createState() => _PublishingSettingsState();
}

class _PublishingSettingsState extends State<PublishingSettings> {
  final owner = TextEditingController(text: 'MacTimiT');
  final repo = TextEditingController(text: 'brb-tracker');
  final token = TextEditingController();
  bool savedToken = false;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final ownerValue = await _storage.read(key: 'github_owner');
      final repoValue = await _storage.read(key: 'github_repo');
      final saved = await _storage.read(key: 'github_token');
      if (!mounted) return;
      owner.text = ownerValue ?? 'MacTimiT';
      repo.text = repoValue ?? 'brb-tracker';
      savedToken = saved?.isNotEmpty == true;
    } catch (e) {
      if (mounted) error = 'Could not read secure settings: $e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(owner.text.trim()) ||
          !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(repo.text.trim())) {
        throw const FormatException('Enter a valid repository owner and name.');
      }
      if (!savedToken && token.text.trim().isEmpty) {
        throw const FormatException('Enter a GitHub token.');
      }
      await _storage.write(key: 'github_owner', value: owner.text.trim());
      await _storage.write(key: 'github_repo', value: repo.text.trim());
      if (token.text.trim().isNotEmpty) {
        await _storage.write(key: 'github_token', value: token.text.trim());
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    owner.dispose();
    repo.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('GitHub publishing')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Your phone publishes report JSON directly to GitHub. No analysis server or PC is involved.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: owner,
          decoration: const InputDecoration(labelText: 'Repository owner'),
        ),
        TextField(
          controller: repo,
          decoration: const InputDecoration(labelText: 'Repository name'),
        ),
        TextField(
          controller: token,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: savedToken
                ? 'Replacement GitHub token (optional)'
                : 'GitHub token',
            helperText: savedToken
                ? 'A token is saved securely on this device.'
                : 'Stored in Android secure storage. Never uploaded with reports.',
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Create a fine-grained personal access token for this repository only, with Contents: read and write. Metadata: read is included automatically. Pages must already use GitHub Actions. Never paste the token into a chat or commit it to Git.',
        ),
        TextButton(
          onPressed: () => launchUrl(
            Uri.https('github.com', '/settings/personal-access-tokens/new'),
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Open GitHub token settings'),
        ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.redAccent)),
        if (busy) const LinearProgressIndicator(),
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Save securely'),
        ),
        if (savedToken)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    await _storage.delete(key: 'github_token');
                    if (mounted) setState(() => savedToken = false);
                  },
            child: const Text('Forget saved token'),
          ),
      ],
    ),
  );
}
