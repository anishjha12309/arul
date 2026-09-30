/** The monthly debit of every mandate made before the cancel-save offer, and of every re-subscribe since. */
export const STANDARD_PRICE_PAISE = 19900;

/** The cancel-save mandate's FIXED monthly debit. Only an `offer: "cancel_99"` setup ever creates one. */
export const OFFER_PRICE_PAISE = 9900;

export const CANCEL_OFFER = "cancel_99";

/** The analytics `offer` value a row's price implies -> 9900 is reachable only through the cancel offer. */
export function offerOfPrice(pricePaise: number | null | undefined): string | null {
  return Number(pricePaise) === OFFER_PRICE_PAISE ? CANCEL_OFFER : null;
}
