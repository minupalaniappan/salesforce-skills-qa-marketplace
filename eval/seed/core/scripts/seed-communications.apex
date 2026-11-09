/**
 * Post-import Apex step 3 of 3 — communication & collateral records (EmailMessage, files).
 *
 * Why Apex and not tree-import:
 *   - EmailMessage is not reliably seedable via `sf data import tree` (it wants a parent via
 *     RelatedToId / an EmailMessageRelation, and tree import does not set the polymorphic
 *     RelatedToId cleanly). Inserting in Apex against the anchor opp is deterministic.
 *   - A file (ContentVersion) + its share link (ContentDocumentLink) is a two-step insert:
 *     you insert the ContentVersion, re-query it for its generated ContentDocumentId, then
 *     insert the link. Tree import cannot express that dependency.
 *
 * What it seeds (so deal-review / customer-voice / handle-objection skills find real written
 * communication attached to the anchor Joja deal, instead of empty EmailMessage / files reads):
 *   - 2 EmailMessage rows on 'Joja Corporation - Warehouse Automation Platform' (a pricing
 *     proposal out, and Joja's reply).
 *   - 1 file 'JojaCola Pricing Proposal.txt' shared to the same opp (ContentVersion +
 *     ContentDocumentLink).
 *
 * Idempotent: re-running does not duplicate — EmailMessages are keyed off Subject on the opp,
 * the file off its Title. Org-agnostic: keys off record Names this repo seeds, never hardcoded Ids.
 *
 * Run: sf apex run --file scripts/seed-communications.apex --target-org <alias>
 */
System.debug('== seed-communications: start ==');

// Anchor opp — everything attaches here.
List<Opportunity> anchors = [SELECT Id FROM Opportunity
                             WHERE Name = 'Joja Corporation - Warehouse Automation Platform' LIMIT 1];
if (anchors.isEmpty()) {
    System.debug('Anchor opp not found; skipping communications seed.');
} else {
    Id oppId = anchors[0].Id;

    // 1) EmailMessage rows (idempotent by Subject on this opp).
    Map<String, Map<String, Object>> wantEmails = new Map<String, Map<String, Object>>{
        'JojaCola Analytics — pricing proposal' => new Map<String, Object>{
            'fromAddress' => 'rep@example.com',
            'fromName'    => 'Account Executive',
            'toAddress'   => 'lewis.thornton@joja.example',
            'incoming'    => false,
            'status'      => '3', // Sent
            'textBody'    => 'Lewis — attached is the JojaCola Analytics pricing proposal we discussed. ' +
                             'It reflects the expanded seat count and a 2-year price lock in exchange for the ' +
                             'multi-year commitment. Happy to walk finance through the TCO model this week.'
        },
        'RE: JojaCola Analytics — pricing proposal' => new Map<String, Object>{
            'fromAddress' => 'lewis.thornton@joja.example',
            'fromName'    => 'Lewis Thornton',
            'toAddress'   => 'rep@example.com',
            'incoming'    => true,
            'status'      => '0', // New (received)
            'textBody'    => 'Thanks — the price lock helps. Procurement is still comparing against a regional ' +
                             'quote, so I need the TCO one-pager before I can take this to the FY27 budget review. ' +
                             'Can you also confirm the data-processing addendum is moving through your legal?'
        }
    };
    Set<String> existingSubjects = new Set<String>();
    for (EmailMessage em : [SELECT Subject FROM EmailMessage WHERE RelatedToId = :oppId]) {
        if (em.Subject != null) existingSubjects.add(em.Subject);
    }
    List<EmailMessage> newEmails = new List<EmailMessage>();
    for (String subj : wantEmails.keySet()) {
        if (existingSubjects.contains(subj)) continue;
        Map<String, Object> f = wantEmails.get(subj);
        newEmails.add(new EmailMessage(
            Subject       = subj,
            RelatedToId   = oppId,
            FromAddress   = (String) f.get('fromAddress'),
            FromName      = (String) f.get('fromName'),
            ToAddress     = (String) f.get('toAddress'),
            Incoming      = (Boolean) f.get('incoming'),
            Status        = (String) f.get('status'),
            MessageDate   = System.now().addDays(-3),
            TextBody      = (String) f.get('textBody')));
    }
    if (!newEmails.isEmpty()) {
        insert newEmails;
        System.debug('Inserted ' + newEmails.size() + ' EmailMessage(s) on the anchor opp.');
    } else {
        System.debug('EmailMessages already present; skipping (idempotent).');
    }

    // 2) File: ContentVersion + ContentDocumentLink to the anchor opp (idempotent by Title).
    final String FILE_TITLE = 'JojaCola Pricing Proposal';
    List<ContentDocumentLink> existingLinks = [
        SELECT Id FROM ContentDocumentLink
        WHERE LinkedEntityId = :oppId
          AND ContentDocument.Title = :FILE_TITLE LIMIT 1];
    if (existingLinks.isEmpty()) {
        ContentVersion cv = new ContentVersion(
            Title        = FILE_TITLE,
            PathOnClient = 'JojaCola Pricing Proposal.txt',
            VersionData  = Blob.valueOf(
                'JojaCola Analytics Expansion — Pricing Proposal\n\n' +
                'Expanded seat tier with a 2-year price lock. Total contract value reflects the ' +
                'multi-year commitment discussed with Joja finance. See TCO model appendix.'));
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = docId,
            LinkedEntityId    = oppId,
            ShareType         = 'V',
            Visibility        = 'AllUsers');
        System.debug('Inserted file "' + FILE_TITLE + '" and shared it to the anchor opp.');
    } else {
        System.debug('File already linked; skipping (idempotent).');
    }
}
System.debug('== seed-communications: done ==');
