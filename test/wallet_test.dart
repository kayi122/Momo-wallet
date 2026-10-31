import 'package:flutter_test/flutter_test.dart';
import 'package:momo_wallet/wallet.dart';

// The Wallet only checks; Firestore saves. These helpers play the part of
// Firestore: they add the checked transactions to a new Wallet.

var _nextId = 1;
var _clock = DateTime(2026, 10, 1);

Transaction _tx(TxType type, int amount, String description) {
  _clock = _clock.add(const Duration(minutes: 1));
  return Transaction(
    id: 'tx${_nextId++}',
    type: type,
    amount: amount,
    description: description,
    date: _clock,
  );
}

Wallet _with(Wallet w, List<Transaction> txs) => Wallet([
      ...w.history,
      for (final t in txs)
        Transaction(
            id: 'tx${_nextId++}',
            type: t.type,
            amount: t.amount,
            description: t.description,
            date: _clock = _clock.add(const Duration(minutes: 1))),
    ]);

/// Like a new account: the three sample transactions, 11,500 RWF.
Wallet _samples() => Wallet([
      _tx(TxType.incoming, 10000, 'Opening balance'),
      _tx(TxType.outgoing, 2500, 'Sent to 0788123456'),
      _tx(TxType.incoming, 4000, 'Received from Keza'),
    ]);

/// A wallet with just the opening balance: 10,000 RWF.
Wallet _opened() => Wallet([_tx(TxType.incoming, 10000, 'Opening balance')]);

Wallet _receive(Wallet w, String amount, String desc) {
  final check = w.checkReceive(amount, desc);
  expect(check.error, isNull);
  return _with(w, [check.tx!]);
}

Wallet _send(Wallet w, String phone, String amount) {
  final check = w.checkSendTransactions(phone, amount);
  expect(check.error, isNull);
  return _with(w, check.txs!);
}

Wallet _cashOut(Wallet w, String amount) {
  final check = w.checkCashOut(amount);
  expect(check.error, isNull);
  return _with(w, [
    Transaction(
        type: TxType.outgoing,
        amount: check.amount!,
        description: 'Cash out',
        date: DateTime.now()),
  ]);
}

void main() {
  test('sample data: balance 11,500 RWF, newest first', () {
    final w = _samples();
    expect(w.balance, 11500);
    expect(w.transactions.first.description, 'Received from Keza');
    final dates = w.transactions.map((t) => t.date).toList();
    for (var i = 1; i < dates.length; i++) {
      expect(dates[i - 1].isAfter(dates[i]), isTrue);
    }
  });

  test('empty wallet: everything is 0', () {
    final s = Wallet([]).stats;
    expect([s.balance, s.totalIn, s.totalOut, s.lowestBalance], [0, 0, 0, 0]);
  });

  test('balance is computed: deleting the 2,500 makes it 14,000', () {
    final w = _samples();
    final sent = w.transactions.firstWhere((t) => t.description.startsWith('Sent'));
    expect(w.checkDelete(sent.id), isNull);
    final without = Wallet(w.history.where((t) => t.id != sent.id).toList());
    expect(without.balance, 14000);
  });

  group('send', () {
    test('0721234567 is refused (not 078/079)', () {
      expect(_opened().checkSend('0721234567', '1000').error,
          contains('078 or 079'));
    });
    test('50 RWF to 0788123456 is refused', () {
      expect(_opened().checkSend('0788123456', '50').error, contains('100 RWF'));
    });
    test('phone must be exactly 10 digits', () {
      final w = _opened();
      expect(w.checkSend('078812345', '1000').error, contains('10 digits'));
      expect(w.checkSend('07881234567', '1000').error, contains('10 digits'));
      expect(w.checkSend('078812345a', '1000').error, contains('10 digits'));
    });
    test('successful send is an OUT "Sent to ..." plus a fee OUT', () {
      final check = _opened().checkSendTransactions('0788123456', '1000');
      expect(check.error, isNull);
      expect(check.txs!.map((t) => t.description),
          ['Sent to 0788123456', 'Send fee (0788123456)']);
      expect(check.txs!.every((t) => !t.isIn), isTrue);
      expect(check.txs![1].amount, sendFee);
      final w = _send(_opened(), '0788123456', '1000');
      expect(w.balance, 10000 - 1000 - sendFee);
    });
  });

  group('cash out', () {
    test('23,700 gives 5000x4, 2000x1, 1000x1, 500x1, 100x2', () {
      final w = _receive(_opened(), '20000', 'Salary');
      final check = w.checkCashOut('23700');
      expect(check.error, isNull);
      expect(check.notes, {5000: 4, 2000: 1, 1000: 1, 500: 1, 100: 2});
      expect(check.notes!.keys.toList(), [5000, 2000, 1000, 500, 100]);
      expect(_cashOut(w, '23700').balance, 30000 - 23700);
    });
    test('250 is refused', () {
      expect(_opened().checkCashOut('250').error, contains('multiple of 100'));
    });
  });

  group('refused amounts', () {
    test('OUT of 1,000,000 is refused: Insufficient balance', () {
      final w = _opened();
      expect(w.checkSend('0788123456', '1000000').error,
          contains('Insufficient balance'));
      expect(w.checkCashOut('1000000').error, contains('Insufficient balance'));
      expect(w.checkCashOut('1,000,000').error, contains('Insufficient balance'));
    });
    for (final bad in ['5k', '0', '-200', '', '12.5']) {
      test('"$bad" is refused everywhere', () {
        final w = _samples();
        expect(w.checkReceive(bad, 'x').error, isNotNull);
        expect(w.checkSend('0788123456', bad).error, isNotNull);
        expect(w.checkCashOut(bad).error, isNotNull);
        expect(w.checkEdit(w.history.first.id, bad, 'x').error, isNotNull);
      });
    }
    test('receive needs a description', () {
      expect(_opened().checkReceive('500', '   ').error, contains('Description'));
    });
  });

  group('statistics', () {
    test('totals and lowest balance after several transactions and a delete',
        () {
      var w = _opened();
      expect(w.stats.lowestBalance, 10000);
      w = _receive(w, '5000', 'From Aline'); // 15,000
      w = _send(w, '0788123456', '12000'); // 3,000 then 2,900 (fee)
      w = _cashOut(w, '2000'); // 900
      w = _receive(w, '4000', 'From Eric'); // 4,900
      var s = w.stats;
      expect(s.totalIn, 10000 + 9000);
      expect(s.totalOut, 12000 + 100 + 2000);
      expect(s.balance, 4900);
      expect(s.lowestBalance, 900);

      // Delete the cash out: 15,000 -> 3,000 -> 2,900 -> 6,900
      final cashOut =
          w.transactions.firstWhere((t) => t.description == 'Cash out');
      expect(w.checkDelete(cashOut.id), isNull);
      final without =
          Wallet(w.history.where((t) => t.id != cashOut.id).toList());
      s = without.stats;
      expect(s.totalOut, 12100);
      expect(s.balance, 6900);
      expect(s.lowestBalance, 2900);

      // Undo puts it back at its date, and everything comes back.
      expect(without.checkRestore(cashOut), isNull);
      final restored = Wallet([...without.history, cashOut]
        ..sort((a, b) => a.date.compareTo(b.date)));
      expect(restored.stats.balance, 4900);
      expect(restored.stats.lowestBalance, 900);
    });

    test('delete refused if the balance would go below 0 at any point', () {
      var w = _opened();
      w = _receive(w, '5000', 'From Aline'); // 15,000
      w = _send(w, '0788123456', '14000'); // 1,000 then 900
      w = _receive(w, '20000', 'Salary'); // 20,900
      final aline =
          w.transactions.firstWhere((t) => t.description == 'From Aline');
      // Without it: 10,000 -> -4,000 : refused, even though the end is fine.
      expect(w.checkDelete(aline.id), contains('below 0'));
    });
  });

  group('edit', () {
    test('editing an amount recomputes the balance', () {
      final w = _samples();
      final sent = w.transactions.firstWhere((t) => t.description.startsWith('Sent'));
      final check = w.checkEdit(sent.id, '3000', 'Sent to 0788123456');
      expect(check.error, isNull);
      expect(check.tx!.id, sent.id);
      expect(check.tx!.date, sent.date);
      final edited = Wallet(
          w.history.map((t) => t.id == sent.id ? check.tx! : t).toList());
      expect(edited.balance, 11000);
    });
    test('an edit that would make the balance go below 0 is refused', () {
      final w = _samples();
      final sent = w.transactions.firstWhere((t) => t.description.startsWith('Sent'));
      expect(w.checkEdit(sent.id, '20000', 'x').error, contains('below 0'));
    });
    test('description cannot be empty', () {
      final w = _samples();
      expect(w.checkEdit(w.history.first.id, '100', ' ').error,
          contains('Description'));
    });
  });
}
