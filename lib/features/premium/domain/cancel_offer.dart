/// The cancel-save offer's id on `POST /payments/initiate`.
const kCancelOffer = 'cancel_99';

/// What the cancel-save offer charges a month, in paise.
const kCancelOfferPricePaise = 9900;

/// `₹199` from 19900 — whole rupees bare, anything else to the paisa.
String rupeesFromPaise(num paise) {
  final rupees = paise / 100;
  final whole = rupees.truncateToDouble() == rupees;
  return '₹${whole ? rupees.toInt() : rupees.toStringAsFixed(2)}';
}
