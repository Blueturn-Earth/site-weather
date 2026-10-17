/**
 * Identity of this deployment.
 *
 * The per-extension site build injects `window.__BT_SITE__` (scripts/build-site.mjs).
 * On epic.projector.earth and in dev it is absent, so the defaults below apply and the
 * full app (extensions menu, EPIC branding) is unchanged.
 *
 * Core reads this instead of importing anything from ext/.
 */

/**
 * @typedef {object} SiteBrand
 * @property {string} name product name (console log)
 * @property {string} aboutTitle About panel heading
 * @property {string} logo About panel logo, page-relative
 * @property {string[] | null} aboutSummary paragraphs replacing the default About text; null = default
 * @property {string | null} shareIntro Web Share intro when an extension is on; null = default
 */

/**
 * @typedef {object} Site
 * @property {string} pinnedExtension extension that is always on (single-extension site), '' = full app
 * @property {SiteBrand} brand
 */

/** @type {SiteBrand} */
const DEFAULT_BRAND = {
  name: 'EPIC Projector Earth',
  aboutTitle: 'EPIC.Projector.Earth',
  logo: './bt/images/logos/LogoPE192.png',
  aboutSummary: null,
  shareIntro: null,
};

const injected = globalThis.__BT_SITE__;

/** @type {Site} */
const site = Object.freeze({
  pinnedExtension: String(injected?.pinnedExtension || ''),
  brand: Object.freeze({
    ...DEFAULT_BRAND,
    ...(injected?.brand || {}),
  }),
});

/** @returns {Site} */
export function getSite() {
  return site;
}
