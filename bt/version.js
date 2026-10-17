import {
  getSite,
} from './site.js';

export const APP_VERSION = '7.743';
console.log(`${getSite().brand.name} ${APP_VERSION}`);
