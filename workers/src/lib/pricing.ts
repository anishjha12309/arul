/** The monthly debit of every mandate made before the cancel-save offer, and of every re-subscribe since. */
export const STANDARD_PRICE_PAISE = 19900;

/** The ₹99 mandate's FIXED monthly debit: only an `offer: "cancel_99"` or `"winback_99"` setup ever creates one. */
export const OFFER_PRICE_PAISE = 9900;

export const CANCEL_OFFER = "cancel_99";

export const WINBACK_OFFER = "winback_99";

/**
 * The analytics `offer` a row's price proves. A ₹99 trial is always a switch (a winback is a paid setup, never a
 * trial); a paid ₹99 row may be either offer and the row does not say which -> no `offer` at all
 */
export function offerOfPrice(pricePaise: number | null | undefined, trialing: boolean): string | null {
  return trialing && Number(pricePaise) === OFFER_PRICE_PAISE ? CANCEL_OFFER : null;
}
