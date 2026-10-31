import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';

import 'wallet.dart';

// Everything that reads or writes Firestore lives here. Each user's data is
// under their own id, where the security rules allow it:
//   users/{uid}/transactions/{transactionId}

/// The signed-in user's transactions: users/{uid}/transactions
CollectionReference<Map<String, dynamic>> myTransactions() {
  final uid = FirebaseAuth.instance.currentUser!.uid;
  return FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('transactions');
}

/// The wallet, live: a new Wallet every time a transaction changes, on this
/// phone, another phone, or in the console.
Stream<Wallet> walletStream() {
  return myTransactions()
      .orderBy('createdAt')
      .snapshots()
      .map((s) => Wallet(s.docs.map(Transaction.fromDoc).toList()));
}

/// Saves new transactions together: all of them, or none.
Future<void> addTransactions(List<Transaction> txs) async {
  final batch = FirebaseFirestore.instance.batch();
  for (final tx in txs) {
    batch.set(myTransactions().doc(), {
      ...tx.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
  await batch.commit();
}

/// Saves an edit of an existing transaction. Its date does not change.
Future<void> updateTransaction(Transaction tx) {
  return myTransactions().doc(tx.id).update(tx.toMap());
}

Future<void> deleteTransaction(String id) {
  return myTransactions().doc(id).delete();
}

/// Undo of a delete: writes the same data back, with the same id and date.
Future<void> restoreTransaction(Transaction tx) {
  return myTransactions().doc(tx.id).set({
    ...tx.toMap(),
    'createdAt': Timestamp.fromDate(tx.date),
  });
}

/// Sample data, written once when a new account is created. The opening
/// balance is a transaction like the others: a fact, not a saved total.
Future<void> addSampleTransactions() async {
  final samples = [
    (description: 'Opening balance', amount: 10000, isIn: true),
    (description: 'Sent to 0788123456', amount: 2500, isIn: false),
    (description: 'Received from Keza', amount: 4000, isIn: true),
  ];
  // Each sample one minute after the other, so their order is certain.
  final start = DateTime.now().subtract(Duration(minutes: samples.length));
  final batch = FirebaseFirestore.instance.batch();
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    batch.set(myTransactions().doc(), {
      'description': s.description,
      'amount': s.amount,
      'isIn': s.isIn,
      'createdAt': Timestamp.fromDate(start.add(Duration(minutes: i))),
    });
  }
  await batch.commit();
}
