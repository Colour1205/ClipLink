// Text that code builds itself - toasts, dialog bodies, status lines - as
// opposed to text the UI shows straight from a resource (Text($r(...))), which
// the framework resolves, and re-resolves on a language change, on its own.
//
// Both helpers read the resource at the moment they are called, in the
// language in effect right then. Never keep what they return in a field or
// @State that outlives that moment (a "computed once at startup" label): it
// would stay in the old language after a system language change. Keep the
// Resource (or a key) and call these where the text is used.
//
// The languages live in resources/base (English, the fallback, so it holds
// every string), resources/en_US and resources/zh_CN; the system picks the
// folder from the device language.

import { common } from '@kit.AbilityKit';

/**
 * A string resource with its placeholders filled in. Placeholders are
 * positional (%1$s, %2$d) so a translation can put the arguments in a
 * different order.
 */
export function resText(context: common.Context, res: Resource, ...args: Array<string | number>): string {
  return context.resourceManager.getStringSync(res.id, ...args);
}

/**
 * A plural resource for `count` ("1 device" / "3 devices"). The count picks
 * the form and is passed again to fill the %d, which is how the resource
 * manager takes it.
 */
export function resCount(context: common.Context, res: Resource, count: number): string {
  return context.resourceManager.getIntPluralStringValueSync(res.id, count, count);
}
