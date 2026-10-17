/** Approved commercial terms. The server freezes these with each accepted block. */
export const DRIVER_BLOCK_TERMS_REVISION = "1.0";
export const DRIVER_BLOCK_TERMS = [
 ["Payment terms", "ToolTag pays weekly on Friday by bank deposit, at 85% of what ToolTag charges for the assigned services. Drivers work as independent contractors and receive a 1099."],
 ["Driver cancellation", "Your driver block starts at the shop one hour before the route starts. Cancel at least one hour before your driver block starts (two hours before the route). For a 2–6 PM route, your block starts at 1 PM and you must cancel by 12 PM. Late cancellations are reviewed based on frequency."],
 ["ToolTag cancellation", "ToolTag may cancel until two hours before the route starts. After that deadline, compensation is $10 if notice is given before you arrive at the shop, or $20 if ToolTag cancels after you arrive at the shop."],
 ["No-show", "The first no-show results in a one-month block, the second in a three-month block, and the third in a permanent ban."],
 ["Vehicle and insurance", "Active vehicle insurance and up-to-date vehicle registration are required to be eligible for a block."],
] as const;
