import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onLogin, required this.onRegister});
  final VoidCallback onLogin;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: leafDark,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Color(0x332E5A27), blurRadius: 12, offset: Offset(0, 5))],
            ),
            child: const Text('L', style: TextStyle(color: paper, fontFamily: 'Georgia', fontSize: 24)),
          ),
          const Spacer(),
          SoftCard(
            color: const Color(0xFF24382C),
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PHILIPPINE LOCAL STORE LOCATOR', style: TextStyle(color: champagne, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                SizedBox(height: 12),
                Text('Find it nearby.\nBuy it there.', style: TextStyle(fontFamily: 'Georgia', fontSize: 34, height: 1.08, color: paper)),
                SizedBox(height: 12),
                Text(
                  'Search participating sari-sari stores, market stalls and vendors. LocalSpot does not take orders or deliveries.',
                  style: TextStyle(color: Color(0xFFD8D0C4), height: 1.5),
                ),
              ],
            ),
          ),
          const Spacer(),
          PrimaryButton('Create an account', onPressed: onRegister),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onLogin,
              child: const Text('Sign in'),
            ),
          ),
        ],
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onBack, required this.onSuccess, required this.onRegister});
  final VoidCallback onBack;
  final VoidCallback onSuccess;
  final VoidCallback onRegister;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController(text: kReleaseMode ? '' : 'maria@localspot.ph');
  final password = TextEditingController(text: kReleaseMode ? '' : 'demo');
  String? error;
  String? emailError;
  String? passwordError;
  var busy = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Sign in', onBack: widget.onBack),
        InfoBanner('${app.connectionNote} Pilot accounts all use the password demo.', icon: Icons.lock_outline),
        const SizedBox(height: 16),
        SoftCard(
          child: Column(
            children: [
              LabeledField('Email', email, keyboardType: TextInputType.emailAddress),
              if (emailError != null) Text(emailError!, style: const TextStyle(color: clay, fontSize: 12)),
              const SizedBox(height: 12),
              LabeledField('Password', password, obscure: true),
              if (passwordError != null) Text(passwordError!, style: const TextStyle(color: clay, fontSize: 12)),
            ],
          ),
        ),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: clay))),
        const SizedBox(height: 18),
        PrimaryButton('Sign in', onPressed: busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  emailError = email.text.contains('@') ? null : 'Enter a valid email.';
                  passwordError = password.text.isEmpty ? 'Enter your password.' : null;
                  error = null;
                });
                if (emailError != null || passwordError != null) {
                  setState(() => busy = false);
                  return;
                }
                final message = await app.login(email.text.trim(), password.text);
                if (!mounted) return;
                setState(() {
                  busy = false;
                  error = message;
                });
                if (message == null) widget.onSuccess();
              }),
        if (!kReleaseMode) ...[
          const SizedBox(height: 22),
          const Eyebrow('QUICK DEMO ACCESS'),
          const SizedBox(height: 10),
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < app.users.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  MenuRow(
                    icon: switch (app.users[i].role) {
                      AppRole.customer => Icons.person_outline,
                      AppRole.owner => Icons.storefront_outlined,
                      AppRole.staff => Icons.badge_outlined,
                      AppRole.admin => Icons.admin_panel_settings_outlined,
                    },
                    title: app.users[i].name,
                    subtitle: '${app.users[i].email} · ${roleLabel(app.users[i].role)}',
                    onTap: () async {
                      final user = app.users[i];
                      final message = await app.login(user.email, user.password.isEmpty ? 'demo' : user.password);
                      if (!mounted) return;
                      if (message != null) {
                        setState(() => error = message);
                      } else {
                        widget.onSuccess();
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
        TextButton(onPressed: widget.onRegister, child: const Text('Need an account? Register')),
      ],
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, required this.onBack, required this.onSuccess});
  final VoidCallback onBack;
  final VoidCallback onSuccess;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  AppRole role = AppRole.customer;
  String? nameError;
  String? emailError;
  String? passwordError;
  var busy = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        PageHeader('Create account', onBack: widget.onBack),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabeledField('Full name', name),
              if (nameError != null) Text(nameError!, style: const TextStyle(color: clay, fontSize: 12)),
              const SizedBox(height: 12),
              LabeledField('Email', email, keyboardType: TextInputType.emailAddress),
              if (emailError != null) Text(emailError!, style: const TextStyle(color: clay, fontSize: 12)),
              const SizedBox(height: 12),
              LabeledField('Password', password, obscure: true),
              if (passwordError != null) Text(passwordError!, style: const TextStyle(color: clay, fontSize: 12)),
              const SizedBox(height: 12),
              FilterMenu<AppRole>(
                label: 'I am joining as',
                value: role,
                items: const [
                  DropdownMenuItem(value: AppRole.customer, child: Text('Customer')),
                  DropdownMenuItem(value: AppRole.owner, child: Text('Store owner')),
                  DropdownMenuItem(value: AppRole.staff, child: Text('Staff')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => role = value);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton('Register', onPressed: busy
            ? null
            : () async {
                setState(() {
                  busy = true;
                  nameError = name.text.trim().isEmpty ? 'Enter your name.' : null;
                  emailError = email.text.trim().contains('@') ? null : 'Enter a valid email.';
                  passwordError = password.text.length < 4 ? 'Use at least 4 characters.' : null;
                });
                if (nameError != null || emailError != null || passwordError != null) {
                  setState(() => busy = false);
                  return;
                }
                final apiError = await app.register(name: name.text.trim(), email: email.text.trim(), password: password.text, role: role);
                if (!context.mounted) return;
                if (apiError != null) {
                  setState(() {
                    busy = false;
                    nameError = apiError.field('name') ?? nameError;
                    emailError = apiError.field('email') ?? emailError;
                    passwordError = apiError.field('password') ?? passwordError;
                  });
                  return;
                }
                widget.onSuccess();
              }),
      ],
    );
  }
}
