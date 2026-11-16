import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

class MessageCenterPage extends StatefulWidget {
  const MessageCenterPage({super.key, required this.onBack, this.store});

  final VoidCallback onBack;
  final Store? store;

  @override
  State<MessageCenterPage> createState() => _MessageCenterPageState();
}

class _MessageCenterPageState extends State<MessageCenterPage> {
  final text = TextEditingController();
  bool loading = true;
  bool sending = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final message = await AppScope.of(context).loadMessages();
    if (!mounted) return;
    setState(() {
      loading = false;
      error = message;
    });
  }

  Future<void> _send() async {
    final body = text.text.trim();
    if (body.isEmpty || widget.store == null) return;
    setState(() {
      sending = true;
      error = null;
    });
    final message = await AppScope.of(
      context,
    ).sendStoreMessage(storeId: widget.store!.id, text: body);
    if (!mounted) return;
    if (message == null) {
      text.clear();
      await _load();
      if (mounted) setState(() => sending = false);
      return;
    }
    setState(() {
      sending = false;
      error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final messages = app.messages;
    final isOwnerInbox = widget.store == null && app.role == AppRole.owner;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader(
          isOwnerInbox ? 'Customer messages' : 'Contact store',
          onBack: widget.onBack,
        ),
        if (widget.store != null) ...[
          InfoBanner(
            'Send a question directly to ${widget.store!.name}. The owner can view it in their Locentra inbox.',
            icon: Icons.chat_bubble_outline,
          ),
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              children: [
                LabeledField('Message', text, maxLines: 5, maxLength: 1000),
                const SizedBox(height: 12),
                PrimaryButton(
                  sending ? 'Sending…' : 'Send message',
                  onPressed: sending ? null : _send,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const SectionHeading('Your messages'),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(error!, style: const TextStyle(color: clay)),
          ),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (messages.isEmpty)
          EmptyNote(
            isOwnerInbox
                ? 'Customer messages will appear here.'
                : 'You have not sent any messages yet.',
            icon: Icons.chat_bubble_outline,
          )
        else
          ...messages.map(
            (message) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOwnerInbox
                          ? '${message.senderName} · ${message.storeName}'
                          : message.storeName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(message.text),
                    const SizedBox(height: 6),
                    Text(
                      '${message.createdAt.toLocal()}${isOwnerInbox ? ' · ${message.senderEmail}' : ''}',
                      style: const TextStyle(color: taupe, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
