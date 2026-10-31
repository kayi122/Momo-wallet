import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'wallet_store.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool newAccount}) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      if (newAccount) {
        await auth.createUserWithEmailAndPassword(
            email: _email.text.trim(), password: _password.text);
        await addSampleTransactions();
      } else {
        await auth.signInWithEmailAndPassword(
            email: _email.text.trim(), password: _password.text);
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _message(e.code));
    } on FirebaseException catch (e) {
      // The account was created, but the sample data could not be saved.
      if (mounted) setState(() => _error = _message(e.code));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account with this email already exists. Log in instead.';
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Wrong email or password.';
      case 'weak-password':
        return 'Choose a stronger password.';
      case 'invalid-email':
        return 'Enter a valid email, like aline@gmail.com';
      case 'too-many-requests':
        return 'Too many attempts. Wait a moment and try again.';
      case 'network-request-failed':
        return 'No internet connection.';
      default:
        return 'Something went wrong ($code).';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.account_balance_wallet,
                      size: 64, color: Color(0xFFFFCC00)),
                  const SizedBox(height: 8),
                  const Text('MoMo Wallet',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 32),
                  TextFormField(
                    key: const Key('loginEmail'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                        labelText: 'Email', border: OutlineInputBorder()),
                    validator: (v) {
                      final email = (v ?? '').trim();
                      if (email.isEmpty) return 'Enter your email';
                      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                          .hasMatch(email)) {
                        return 'Enter a valid email, like aline@gmail.com';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('loginPassword'),
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Password', border: OutlineInputBorder()),
                    validator: (v) =>
                        (v ?? '').length < 6 ? 'At least 6 characters' : null,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Text(_error!,
                        key: const Key('loginError'),
                        style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : () => _submit(newAccount: false),
                    child: const Text('Log in'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _submit(newAccount: true),
                    child: const Text('Create account'),
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
