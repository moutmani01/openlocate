import _sodium from "libsodium-wrappers-sumo";

let ready: Promise<void> | null = null;

/** Must be awaited once before any other function in this package is called. */
export function initCrypto(): Promise<void> {
  ready ??= _sodium.ready;
  return ready;
}

export function sodium(): typeof _sodium {
  return _sodium;
}
