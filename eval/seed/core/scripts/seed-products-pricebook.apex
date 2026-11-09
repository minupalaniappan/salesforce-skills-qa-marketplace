/**
 * Post-import Apex step 1 of 2 — Products, standard Pricebook, and Opportunity line items.
 *
 * Why Apex and not tree-import: Product2/Pricebook2/PricebookEntry/OpportunityLineItem
 * cannot be seeded reliably via `sf data import tree` — the STANDARD pricebook ships
 * INACTIVE in a fresh scratch org and has no addressable Id in a tree file, and an
 * OpportunityLineItem requires a PricebookEntry that is created against that activated
 * standard pricebook. So this runs after the tree import.
 *
 * Idempotent: re-running does not duplicate the Product, entry, or line items.
 * Org-agnostic: keys off record Names this repo seeds ('Joja Corporation - JojaCola Analytics Expansion',
 * 'Joja Corporation - Community Center Pilot', 'H360 Test - Warehouse License'), never hardcoded Ids.
 *
 * IMPORTANT — target-opp choice: line items go on the EXPANSION and PILOT opps, deliberately
 * NOT on the anchor 'Joja Corporation - Warehouse Automation Platform'. Adding OLIs makes Opportunity.Amount a
 * read-only rollup of the line items. Here each OLI's UnitPrice is set to the opp's seeded Amount, so
 * the rollup preserves that value. The anchor+renewal are still kept OLI-free because
 * trigger-opp-history.apex writes their Amount directly (a read-only rollup would block that write
 * and collide). Because those two opps carry no line items, the two Apex scripts are order-independent.
 *
 * Run: sf apex run --file scripts/seed-products-pricebook.apex --target-org <alias>
 */
System.debug('== seed-products-pricebook: start ==');

// 1) Activate the standard price book (scratch orgs ship it inactive).
Pricebook2 std = [SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
if (!std.IsActive) {
    std.IsActive = true;
    update std;
    System.debug('Activated standard pricebook ' + std.Id);
}

// 2) Product2 (idempotent by exact catalog Name, with duplicate detection).
final String PROD_NAME = 'H360 Test - Warehouse License';
final String ANALYTICS_NAME = 'H360 Test - Analytics License';
List<Product2> existingProd = [SELECT Id, ProductCode, IsActive FROM Product2 WHERE Name = :PROD_NAME];
System.assert(existingProd.size() <= 1, 'Duplicate Warehouse License products');
Product2 prod;
if (existingProd.isEmpty()) {
    prod = new Product2(Name = PROD_NAME, ProductCode = 'H360-PLAT', IsActive = true,
                        Description = 'Test product for expansion-whitespace / OLI reads.');
    insert prod;
    System.debug('Inserted product ' + prod.Id);
} else {
    prod = existingProd[0];
    if (prod.ProductCode != 'H360-PLAT' || !prod.IsActive) {
        prod.ProductCode = 'H360-PLAT';
        prod.IsActive = true;
        update prod;
    }
}

List<Product2> existingAnalytics = [SELECT Id, ProductCode, IsActive FROM Product2 WHERE Name = :ANALYTICS_NAME];
System.assert(existingAnalytics.size() <= 1, 'Duplicate Analytics License products');
Product2 analytics;
if (existingAnalytics.isEmpty()) {
    analytics = new Product2(Name = ANALYTICS_NAME, ProductCode = 'H360-ANALYTICS', IsActive = true,
                             Description = 'Catalog-only eval product; intentionally has no Joja OLI.');
    insert analytics;
    System.debug('Inserted catalog-only product ' + analytics.Id);
} else {
    analytics = existingAnalytics[0];
    if (analytics.ProductCode != 'H360-ANALYTICS' || !analytics.IsActive) {
        analytics.ProductCode = 'H360-ANALYTICS';
        analytics.IsActive = true;
        update analytics;
    }
}

// 3) Standard PricebookEntry for the product (idempotent).
List<PricebookEntry> stdEntries = [
    SELECT Id, UnitPrice, IsActive FROM PricebookEntry
    WHERE Product2Id = :prod.Id AND Pricebook2Id = :std.Id];
System.assert(stdEntries.size() <= 1, 'Duplicate Warehouse License standard entries');
PricebookEntry stdPbe;
if (stdEntries.isEmpty()) {
    stdPbe = new PricebookEntry(Pricebook2Id = std.Id, Product2Id = prod.Id,
                                UnitPrice = 50000, IsActive = true);
    insert stdPbe;
    System.debug('Inserted standard PricebookEntry ' + stdPbe.Id);
} else {
    stdPbe = stdEntries[0];
    if (stdPbe.UnitPrice != 50000 || !stdPbe.IsActive) {
        stdPbe.UnitPrice = 50000;
        stdPbe.IsActive = true;
        update stdPbe;
    }
}

List<PricebookEntry> analyticsEntries = [
    SELECT Id, UnitPrice, IsActive FROM PricebookEntry
    WHERE Product2Id = :analytics.Id AND Pricebook2Id = :std.Id];
System.assert(analyticsEntries.size() <= 1, 'Duplicate Analytics License standard entries');
if (analyticsEntries.isEmpty()) {
    insert new PricebookEntry(Pricebook2Id = std.Id, Product2Id = analytics.Id,
                              UnitPrice = 90000, IsActive = true);
} else if (analyticsEntries[0].UnitPrice != 90000 || !analyticsEntries[0].IsActive) {
    PricebookEntry analyticsEntry = analyticsEntries[0];
    analyticsEntry.UnitPrice = 90000;
    analyticsEntry.IsActive = true;
    update analyticsEntry;
}

// 4) Attach line items to the expansion + pilot opportunities (idempotent by opp+entry).
//    NOT the anchor/renewal opps — those get Amount set by trigger-opp-history.apex, and OLIs
//    would turn Amount into a read-only rollup (see header note).
List<Opportunity> opps = [
    SELECT Id, Amount, Pricebook2Id FROM Opportunity
    WHERE Name IN ('Joja Corporation - JojaCola Analytics Expansion', 'Joja Corporation - Community Center Pilot')];
List<Opportunity> oppsToFixPb = new List<Opportunity>();
for (Opportunity o : opps) {
    if (o.Pricebook2Id == null) { o.Pricebook2Id = std.Id; oppsToFixPb.add(o); }
}
if (!oppsToFixPb.isEmpty()) update oppsToFixPb;

Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();
Set<Id> alreadyLined = new Set<Id>();
for (OpportunityLineItem oli : [SELECT OpportunityId FROM OpportunityLineItem
                                WHERE OpportunityId IN :oppIds AND PricebookEntryId = :stdPbe.Id]) {
    alreadyLined.add(oli.OpportunityId);
}
List<OpportunityLineItem> newOlis = new List<OpportunityLineItem>();
for (Opportunity o : opps) {
    if (!alreadyLined.contains(o.Id)) {
        // Adding an OLI turns Opportunity.Amount into a read-only rollup of its line items.
        // Set Quantity 1 @ UnitPrice = the opp's seeded Amount so the rollup PRESERVES the
        // seeded value (e.g. 120k / 60k) rather than overwriting it with a flat price.
        Decimal unitPrice = (o.Amount == null ? 50000 : o.Amount);
        newOlis.add(new OpportunityLineItem(
            OpportunityId = o.Id, PricebookEntryId = stdPbe.Id,
            Quantity = 1, UnitPrice = unitPrice));
    }
}
if (!newOlis.isEmpty()) {
    insert newOlis;
    System.debug('Inserted ' + newOlis.size() + ' OpportunityLineItem(s)');
}
System.assertEquals(0, [
    SELECT count() FROM OpportunityLineItem
    WHERE Opportunity.Account.Name = 'Joja Corporation' AND PricebookEntry.Product2Id = :analytics.Id
], 'Analytics License must remain catalog-only on Joja opportunities');
System.debug('== seed-products-pricebook: done ==');
