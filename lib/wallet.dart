import 'package:cloud_firestore/cloud_firestore.dart'
    show DocumentSnapshot, Timestamp;

/// IN = money comes into the wallet, OUT = money leaves it.
enum TxType { incoming, outgoing }

/// One transaction: one Firestore document in users/{uid}/transactions.
class Transaction {
  final String id; // the Firestore document id ('' before it is saved)
  final TxType type;
  final int amount; // always a positive whole number of RWF
  final String description;
  final DateTime date;

  const Transaction({
    this.id = '',
    required this.type,
    required this.amount,
    required this.description,
    required this.date,
  });

  bool get isIn => type == TxType.incoming;

  /// How this transaction changes the balance (+ for IN, - for OUT).
  int get signedAmount => isIn ? amount : -amount;

  Transaction copyWith({int? amount, String? description}) => Transaction(
        id: id,
        type: type,
        amount: amount ?? this.amount,
        description: description ?? this.description,
        date: date,
      );

  /// The facts saved in Firestore. createdAt is added by the writer, so the
  /// server can set it.
  Map<String, dynamic> toMap() => {
        'description': description,
        'amount': amount,
        'isIn': isIn,
      };

  factory Transaction.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Transaction(
      id: doc.id,
      type: data['isIn'] as bool ? TxType.incoming : TxType.outgoing,
      amount: (data['amount'] as num).toInt(),
      description: data['description'] as String,
      // createdAt is null for a moment, until the server sets the time.
      date: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

/// Totals and the lowest balance, recomputed from the full history.
class Stats {
  final int totalIn;
  final int totalOut;
  final int lowestBalance;
  final int balance;

  const Stats(this.totalIn, this.totalOut, this.lowestBalance, this.balance);
}

/// The notes an agent hands out, biggest first.
const List<int> agentNotes = [5000, 2000, 1000, 500, 100];

/// Fee charged on every send, recorded as its own OUT.
const int sendFee = 100;

/// Turns user text into a whole number of RWF above 0, or explains why not.
/// Spaces and thousands separators are allowed ("1,000"), anything else
/// ("5k", "-200", "12.5") is refused.
({int? value, String? error}) parseAmount(String text) {
  final cleaned = text.replaceAll(RegExp(r'[\s,]'), '');
  if (cleaned.isEmpty) {
    return (value: null, error: 'Enter an amount.');
  }
  if (!RegExp(r'^\d+$').hasMatch(cleaned)) {
    return (value: null, error: 'Amount must be a whole number (digits only).');
  }
  final value = int.tryParse(cleaned);
  if (value == null) {
    return (value: null, error: 'Amount is too large.');
  }
  if (value <= 0) {
    return (value: null, error: 'Amount must be above 0.');
  }
  return (value: value, error: null);
}

/// Returns null if the phone number is valid, otherwise which rule failed.
String? validatePhone(String text) {
  final phone = text.replaceAll(' ', '');
  if (!RegExp(r'^\d{10}$').hasMatch(phone)) {
    return 'Phone number must be exactly 10 digits.';
  }
  if (!phone.startsWith('078') && !phone.startsWith('079')) {
    return 'Phone number must start with 078 or 079.';
  }
  return null;
}

/// Splits [amount] into agent notes, biggest first, e.g. 23,700 ->
/// {5000: 4, 2000: 1, 1000: 1, 500: 1, 100: 2}. Only notes actually used
/// are included. [amount] must be a multiple of 100.
Map<int, int> breakIntoNotes(int amount) {
  final result = <int, int>{};
  var left = amount;
  for (final note in agentNotes) {
    final count = left ~/ note;
    if (count > 0) {
      result[note] = count;
      left -= count * note;
    }
  }
  return result;
}

/// Formats 23700 as "23,700".
String formatRwf(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}$buffer';
}

/// The wallet at one moment: the transactions Firestore delivered, oldest
/// first. Only the transactions are saved; the balance and every statistic
/// are computed from them, so they can never disagree.
///
/// Nothing here writes: the check methods say whether a change is allowed,
/// and wallet_store.dart saves it.
class Wallet {
  final List<Transaction> history; // oldest first

  Wallet(List<Transaction> history) : history = List.unmodifiable(history);

  /// Newest first, as the wallet screen shows them.
  List<Transaction> get transactions => history.reversed.toList();

  Stats get stats => computeStats(history);
  int get balance => stats.balance;

  Transaction? byId(String id) {
    for (final tx in history) {
      if (tx.id == id) return tx;
    }
    return null;
  }

  /// Balance right after [tx] happened.
  int balanceAfter(Transaction tx) {
    var running = 0;
    for (final t in history) {
      running += t.signedAmount;
      if (t.id == tx.id) break;
    }
    return running;
  }

  /// Replays [history] from 0. The opening balance is a transaction like any
  /// other, so it is part of the history too.
  static Stats computeStats(List<Transaction> history) {
    var running = 0;
    int? lowest;
    var totalIn = 0;
    var totalOut = 0;
    for (final tx in history) {
      running += tx.signedAmount;
      if (tx.isIn) {
        totalIn += tx.amount;
      } else {
        totalOut += tx.amount;
      }
      if (lowest == null || running < lowest) lowest = running;
    }
    return Stats(totalIn, totalOut, lowest ?? 0, running);
  }

  /// A history is possible only if the balance never goes below 0.
  static bool _isPossible(List<Transaction> history) =>
      computeStats(history).lowestBalance >= 0;

  // ---- Money in -----------------------------------------------------------

  /// Checks an IN. Returns the transaction to save, or the reason it is
  /// refused.
  ({Transaction? tx, String? error}) checkReceive(
      String amountText, String description) {
    final parsed = parseAmount(amountText);
    if (parsed.error != null) return (tx: null, error: parsed.error);
    final desc = description.trim();
    if (desc.isEmpty) return (tx: null, error: 'Description cannot be empty.');
    return (
      tx: Transaction(
        type: TxType.incoming,
        amount: parsed.value!,
        description: desc,
        date: DateTime.now(),
      ),
      error: null,
    );
  }

  // ---- Money out ----------------------------------------------------------

  /// Checks a send without moving money. Returns the amount or the reason.
  ({int? amount, String? error}) checkSend(String phoneText, String amountText) {
    final phoneError = validatePhone(phoneText);
    if (phoneError != null) return (amount: null, error: phoneError);
    final parsed = parseAmount(amountText);
    if (parsed.error != null) return (amount: null, error: parsed.error);
    final amount = parsed.value!;
    if (amount < 100) {
      return (amount: null, error: 'Minimum amount to send is 100 RWF.');
    }
    if (amount + sendFee > balance) {
      return (
        amount: null,
        error: 'Insufficient balance: sending ${formatRwf(amount)} RWF costs '
            '${formatRwf(amount + sendFee)} RWF with the fee, you have '
            '${formatRwf(balance)} RWF.',
      );
    }
    return (amount: amount, error: null);
  }

  /// A send is two OUTs: "Sent to ..." plus the fee. Returns them, or the
  /// reason the send is refused.
  ({List<Transaction>? txs, String? error}) checkSendTransactions(
      String phoneText, String amountText) {
    final check = checkSend(phoneText, amountText);
    if (check.error != null) return (txs: null, error: check.error);
    final phone = phoneText.replaceAll(' ', '');
    final now = DateTime.now();
    return (
      txs: [
        Transaction(
            type: TxType.outgoing,
            amount: check.amount!,
            description: 'Sent to $phone',
            date: now),
        Transaction(
            type: TxType.outgoing,
            amount: sendFee,
            description: 'Send fee ($phone)',
            date: now),
      ],
      error: null,
    );
  }

  /// Checks a cash out without moving money. Returns the amount and the notes
  /// the agent will hand over, or the reason it is refused.
  ({int? amount, Map<int, int>? notes, String? error}) checkCashOut(
      String amountText) {
    final parsed = parseAmount(amountText);
    if (parsed.error != null) {
      return (amount: null, notes: null, error: parsed.error);
    }
    final amount = parsed.value!;
    if (amount % 100 != 0) {
      return (
        amount: null,
        notes: null,
        error: 'Amount must be a multiple of 100 RWF '
            '(the smallest note is 100 RWF).',
      );
    }
    if (amount > balance) {
      return (
        amount: null,
        notes: null,
        error: 'Insufficient balance: you have ${formatRwf(balance)} RWF.',
      );
    }
    return (amount: amount, notes: breakIntoNotes(amount), error: null);
  }

  // ---- Edit, delete & undo ------------------------------------------------

  /// Checks an edit of [id]'s amount and description. The edited history must
  /// still never go below 0.
  ({Transaction? tx, String? error}) checkEdit(
      String id, String amountText, String description) {
    final index = history.indexWhere((t) => t.id == id);
    if (index == -1) return (tx: null, error: 'Transaction not found.');
    final parsed = parseAmount(amountText);
    if (parsed.error != null) return (tx: null, error: parsed.error);
    final desc = description.trim();
    if (desc.isEmpty) return (tx: null, error: 'Description cannot be empty.');

    final edited =
        history[index].copyWith(amount: parsed.value!, description: desc);
    final after = [...history]..[index] = edited;
    if (!_isPossible(after)) {
      return (
        tx: null,
        error: 'Cannot save: with this amount the balance would go below 0 '
            'at some point in the history.',
      );
    }
    return (tx: edited, error: null);
  }

  /// Checks a delete. Refused if the history without it would make the
  /// balance go below 0 at any point.
  String? checkDelete(String id) {
    final index = history.indexWhere((t) => t.id == id);
    if (index == -1) return 'Transaction not found.';
    final without = [...history]..removeAt(index);
    if (!_isPossible(without)) {
      return 'Cannot delete: without it the balance would go below 0 '
          'at some point in the history.';
    }
    return null;
  }

  /// Checks putting a deleted transaction back at its date.
  String? checkRestore(Transaction tx) {
    final restored = [...history, tx]..sort((a, b) => a.date.compareTo(b.date));
    if (!_isPossible(restored)) {
      return 'Cannot undo: putting it back would make the balance go below 0.';
    }
    return null;
  }
}
