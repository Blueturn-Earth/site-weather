import {
  getSite,
} from './site.js';

export const APP_VERSION = '8.314';
console.log(`${getSite().brand.name} ${APP_VERSION}`);
