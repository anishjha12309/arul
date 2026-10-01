/// The cancel-save offer's id on `POST /payments/initiate`: a live ₹199 plan switched to ₹99.
const kCancelOffer = 'cancel_99';

/// The returning user's offer id: a fresh ₹99 plan where no live one exists. A sale, not a switch.
const kWinbackOffer = 'winback_99';

/// What the cancel-save offer charges a month, in paise.
const kCancelOfferPricePaise = 9900;

/// How long one offer sheet holds the price. True per sheet (CCPA "false urgency"); the server
/// never enforces it, and the next Cancel tap starts a fresh hold.
const kCancelOfferHold = Duration(minutes: 10);

/// `₹199` from 19900 — whole rupees bare, anything else to the paisa.
String rupeesFromPaise(num paise) {
  final rupees = paise / 100;
  final whole = rupees.truncateToDouble() == rupees;
  return '₹${whole ? rupees.toInt() : rupees.toStringAsFixed(2)}';
}
