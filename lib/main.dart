import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseFirestore;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'auth_gate.dart';
import 'wallet.dart';
import 'wallet_store.dart';

const momoYellow = Color(0xFFFFCC00);
const inGreen = Color(0xFF1B8A3A);
const outRed = Color(0xFFC62828);

/// Run with --dart-define=USE_EMULATOR=true to use the Firebase Local
/// Emulator Suite (firebase emulators:start) instead of the real project.
const useEmulator = bool.fromEnvironment('USE_EMULATOR');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (useEmulator) {
    // A "demo-" project only exists in the emulator: no real keys needed.
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'demo-key',
        appId: '1:1:web:1',
        messagingSenderId: '1',
        projectId: 'demo-momo-wallet',
      ),
    );
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
    // On the web a saved login is restored before the emulator is connected,
    // which sends the next sign-in to the real servers. Keep it in memory.
    if (kIsWeb) await FirebaseAuth.instance.setPersistence(Persistence.NONE);
    FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8080);
  } else {
    await Firebase.initializeApp();
  }
  runApp(const MoMoApp());
}

class MoMoApp extends StatelessWidget {
  const MoMoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MoMo Wallet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: momoYellow),
        appBarTheme: const AppBarTheme(
          backgroundColor: momoYellow,
          foregroundColor: Colors.black,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ===========================================================================
// Live data
// ===========================================================================

/// Listens to the user's transactions in Firestore and rebuilds with the
/// latest Wallet every time they change. Shows the loading and error states,
/// so every screen that uses it has them.
class WalletBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, Wallet wallet) builder;

  const WalletBuilder({super.key, required this.builder});

  @override
  State<WalletBuilder> createState() => _WalletBuilderState();
}

class _WalletBuilderState extends State<WalletBuilder> {
  // Created once, so a rebuild does not start a new listener.
  final Stream<Wallet> _stream = walletStream();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Wallet>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48, color: outRed),
                  const SizedBox(height: 12),
                  Text(
                    'Could not load your transactions.\n${snapshot.error}',
                    key: const Key('loadError'),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return widget.builder(context, snapshot.data!);
      },
    );
  }
}

/// Starts a Firestore write without waiting for it: the live list already
/// shows the change, even offline. If the server refuses it, say so.
void saveInBackground(ScaffoldMessengerState messenger, Future<void> write) {
  write.catchError((Object e) {
    messenger.showSnackBar(SnackBar(
      content: Text('Could not save: $e'),
      backgroundColor: outRed,
    ));
  });
}

void showError(BuildContext context, String error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(error), backgroundColor: outRed));
}

// ===========================================================================
// Wallet screen
// ===========================================================================

enum TxFilter { all, incoming, outgoing }

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  TxFilter _filter = TxFilter.all;

  /// The latest wallet the stream delivered, for delete and undo.
  Wallet? _wallet;

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _delete(Transaction tx) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: Text('${tx.description}\n'
            '${tx.isIn ? '+' : '-'}${formatRwf(tx.amount)} RWF'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              key: const Key('confirmDelete'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: outRed))),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    final error = _wallet?.checkDelete(tx.id);
    if (error != null) {
      showError(context, error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    saveInBackground(messenger, deleteTransaction(tx.id));
    messenger.showSnackBar(SnackBar(
      content: Text('Deleted "${tx.description}"'),
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () {
          final undoError = _wallet?.checkRestore(tx);
          if (undoError != null) {
            messenger.showSnackBar(
                SnackBar(content: Text(undoError), backgroundColor: outRed));
            return;
          }
          saveInBackground(messenger, restoreTransaction(tx));
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('MoMo Wallet'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: WalletBuilder(
        builder: (context, wallet) {
          _wallet = wallet;
          final stats = wallet.stats;
          final txs = wallet.transactions.where((t) {
            switch (_filter) {
              case TxFilter.all:
                return true;
              case TxFilter.incoming:
                return t.isIn;
              case TxFilter.outgoing:
                return !t.isIn;
            }
          }).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _BalanceCard(balance: stats.balance, email: email),
              const SizedBox(height: 12),
              _StatsRow(stats: stats),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      key: const Key('receiveButton'),
                      icon: Icons.call_received,
                      label: 'Receive',
                      onTap: () => _open(const ReceiveScreen()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      key: const Key('sendButton'),
                      icon: Icons.send,
                      label: 'Send',
                      onTap: () => _open(const SendScreen()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      key: const Key('cashOutButton'),
                      icon: Icons.payments,
                      label: 'Cash out',
                      onTap: () => _open(const CashOutScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('Transactions',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  SegmentedButton<TxFilter>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: TxFilter.all, label: Text('All')),
                      ButtonSegment(
                          value: TxFilter.incoming, label: Text('IN')),
                      ButtonSegment(
                          value: TxFilter.outgoing, label: Text('OUT')),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (s) =>
                        setState(() => _filter = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (wallet.history.isEmpty)
                const _EmptyState(
                    text: 'No transactions yet.\nTap Receive to add money.')
              else if (txs.isEmpty)
                const _EmptyState(text: 'No transactions of this kind.'),
              for (final tx in txs)
                _TransactionTile(
                  tx: tx,
                  onTap: () => _open(
                    TransactionDetailsScreen(txId: tx.id, onDelete: _delete),
                  ),
                  onLongPress: () => _delete(tx),
                  onDelete: () => _delete(tx),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;

  const _EmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.receipt_long, size: 40, color: Colors.black38),
          const SizedBox(height: 8),
          Text(text, key: const Key('emptyState'), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final int balance;
  final String email;

  const _BalanceCard({required this.balance, required this.email});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: momoYellow,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(
          children: [
            const Text('Balance', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 6),
            Text(
              '${formatRwf(balance)} RWF',
              key: const Key('balanceText'),
              style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(email, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final Stats stats;

  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, int value, Color color, Key key) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Column(
                children: [
                  Text(label,
                      style: const TextStyle(fontSize: 12),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text(
                    formatRwf(value),
                    key: key,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: color),
                  ),
                ],
              ),
            ),
          ),
        );

    return Row(
      children: [
        stat('Total IN', stats.totalIn, inGreen, const Key('totalIn')),
        stat('Total OUT', stats.totalOut, outRed, const Key('totalOut')),
        stat('Lowest balance', stats.lowestBalance, Colors.black87,
            const Key('lowestBalance')),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton(
      {super.key, required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14)),
      child: Column(
        children: [Icon(icon), const SizedBox(height: 4), Text(label)],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final Transaction tx;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  const _TransactionTile(
      {required this.tx,
      required this.onTap,
      required this.onLongPress,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final color = tx.isIn ? inGreen : outRed;
    return Card(
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Text(tx.isIn ? 'IN' : 'OUT',
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        title: Text(tx.description),
        subtitle: Text(formatDate(tx.date)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${tx.isIn ? '+' : '-'}${formatRwf(tx.amount)}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Shows a refusal (red) or success (green) message under a form.
class _Message extends StatelessWidget {
  final String text;
  final bool isError;

  const _Message({required this.text, required this.isError});

  @override
  Widget build(BuildContext context) {
    final color = isError ? outRed : inGreen;
    return Container(
      key: const Key('formMessage'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(isError ? Icons.block : Icons.check_circle, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}

// ===========================================================================
// Receive money
// ===========================================================================

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  void _submit(Wallet wallet) {
    final check = wallet.checkReceive(_amount.text, _description.text);
    if (check.error != null) {
      setState(() => _error = check.error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    saveInBackground(messenger, addTransactions([check.tx!]));
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('Money received')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive money')),
      body: WalletBuilder(
        builder: (context, wallet) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const Key('receiveAmount'),
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Amount (RWF)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('receiveDescription'),
              controller: _description,
              decoration: const InputDecoration(
                  labelText: 'Description (e.g. Received from Aline)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _Message(text: _error!, isError: true),
              const SizedBox(height: 16),
            ],
            FilledButton(
              key: const Key('receiveSubmit'),
              onPressed: () => _submit(wallet),
              child: const Text('Receive'),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Send money
// ===========================================================================

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _phone = TextEditingController();
  final _amount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit(Wallet wallet) {
    final check = wallet.checkSendTransactions(_phone.text, _amount.text);
    if (check.error != null) {
      setState(() => _error = check.error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    saveInBackground(messenger, addTransactions(check.txs!));
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Sent to ${_phone.text.replaceAll(' ', '')}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send money')),
      body: WalletBuilder(
        builder: (context, wallet) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const Key('sendPhone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Phone number (078… or 079…)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('sendAmount'),
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Amount (RWF, at least 100)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(
                'A fee of ${formatRwf(sendFee)} RWF is charged on every send. '
                'Balance: ${formatRwf(wallet.balance)} RWF.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _Message(text: _error!, isError: true),
              const SizedBox(height: 16),
            ],
            FilledButton(
              key: const Key('sendSubmit'),
              onPressed: () => _submit(wallet),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Cash out
// ===========================================================================

class CashOutScreen extends StatefulWidget {
  const CashOutScreen({super.key});

  @override
  State<CashOutScreen> createState() => _CashOutScreenState();
}

class _CashOutScreenState extends State<CashOutScreen> {
  final _amount = TextEditingController();
  String? _error;
  Map<int, int>? _notes; // shown before confirming
  String _checkedText = '';

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _check(Wallet wallet) {
    final check = wallet.checkCashOut(_amount.text);
    setState(() {
      _error = check.error;
      _notes = check.notes;
      _checkedText = _amount.text;
    });
  }

  /// Re-checks everything with the latest wallet, since the balance may have
  /// changed (even on another phone) since the notes were shown.
  void _confirm(Wallet wallet) {
    final check = wallet.checkCashOut(_checkedText);
    if (check.error != null) {
      setState(() {
        _error = check.error;
        _notes = null;
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    saveInBackground(
      messenger,
      addTransactions([
        Transaction(
          type: TxType.outgoing,
          amount: check.amount!,
          description: 'Cash out',
          date: DateTime.now(),
        ),
      ]),
    );
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('Cash out done')));
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return Scaffold(
      appBar: AppBar(title: const Text('Cash out')),
      body: WalletBuilder(
        builder: (context, wallet) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const Key('cashOutAmount'),
              controller: _amount,
              keyboardType: TextInputType.number,
              // Changing the amount hides the old notes until checked again.
              onChanged: (_) => setState(() {
                _notes = null;
                _error = null;
              }),
              decoration: const InputDecoration(
                  labelText: 'Amount (RWF, multiple of 100)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const Key('cashOutCheck'),
              onPressed: () => _check(wallet),
              child: const Text('Show notes'),
            ),
            const SizedBox(height: 16),
            if (_error != null) _Message(text: _error!, isError: true),
            if (notes != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'The agent will hand you '
                          '${formatRwf(notes.entries.fold(0, (s, e) => s + e.key * e.value))} RWF:',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      for (final e in notes.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.money, color: inGreen),
                              const SizedBox(width: 8),
                              Text('${formatRwf(e.key)} RWF',
                                  style: const TextStyle(fontSize: 16)),
                              const Spacer(),
                              Text('× ${e.value}',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      const Divider(),
                      Text(
                        notes.entries
                            .map((e) => '${formatRwf(e.key)} × ${e.value}')
                            .join(' · '),
                        key: const Key('notesSummary'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('cashOutConfirm'),
                onPressed: () => _confirm(wallet),
                child: const Text('Confirm'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Transaction details
// ===========================================================================

class TransactionDetailsScreen extends StatelessWidget {
  final String txId;
  final void Function(Transaction) onDelete;

  const TransactionDetailsScreen(
      {super.key, required this.txId, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transaction details')),
      body: WalletBuilder(
        builder: (context, wallet) {
          final tx = wallet.byId(txId);
          if (tx == null) {
            return const Center(child: Text('This transaction was deleted.'));
          }
          final color = tx.isIn ? inGreen : outRed;
          Widget row(String label, String value) => ListTile(
                title: Text(label),
                trailing: Text(value,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Text(
                  '${tx.isIn ? '+' : '-'}${formatRwf(tx.amount)} RWF',
                  style: TextStyle(
                      fontSize: 34, fontWeight: FontWeight.bold, color: color),
                ),
              ),
              const SizedBox(height: 4),
              Center(child: Text(tx.description)),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    row('Type', tx.isIn ? 'IN' : 'OUT'),
                    row('Amount', '${formatRwf(tx.amount)} RWF'),
                    row('Description', tx.description),
                    row('Date', formatDate(tx.date)),
                    row('Balance after',
                        '${formatRwf(wallet.balanceAfter(tx))} RWF'),
                    row('Transaction ID', tx.id),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const Key('editTransaction'),
                icon: const Icon(Icons.edit),
                label: const Text('Edit transaction'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => EditTransactionScreen(tx: tx))),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: outRed),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete transaction'),
                onPressed: () {
                  Navigator.of(context).pop();
                  onDelete(tx);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Edit a transaction
// ===========================================================================

class EditTransactionScreen extends StatefulWidget {
  final Transaction tx;

  const EditTransactionScreen({super.key, required this.tx});

  @override
  State<EditTransactionScreen> createState() => _EditTransactionScreenState();
}

class _EditTransactionScreenState extends State<EditTransactionScreen> {
  late final _amount = TextEditingController(text: '${widget.tx.amount}');
  late final _description =
      TextEditingController(text: widget.tx.description);
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save(Wallet wallet) {
    final check =
        wallet.checkEdit(widget.tx.id, _amount.text, _description.text);
    if (check.error != null) {
      setState(() => _error = check.error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    saveInBackground(messenger, updateTransaction(check.tx!));
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('Transaction updated')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.tx.isIn ? 'Edit IN' : 'Edit OUT')),
      body: WalletBuilder(
        builder: (context, wallet) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const Key('editAmount'),
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Amount (RWF)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('editDescription'),
              controller: _description,
              decoration: const InputDecoration(
                  labelText: 'Description', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              _Message(text: _error!, isError: true),
              const SizedBox(height: 16),
            ],
            FilledButton(
              key: const Key('editSave'),
              onPressed: () => _save(wallet),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
