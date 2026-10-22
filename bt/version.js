import {
  getSite,
} from './site.js';

export const APP_VERSION = '8.076';
console.log(`${getSite().brand.name} ${APP_VERSION}`);
