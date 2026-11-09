/**
 * Post-import Apex finalizer — generate OpportunityHistory and leave the anchor records in
 * their exact expected state.
 *
 * OpportunityHistory cannot be inserted directly. The two current-week Event fixtures also
 * cannot use rolling dates in a tree-import file, so this final step normalizes their schedule
 * after every import. It fails closed on ambiguous named records instead of mutating one chosen
 * by LIMIT.
 *
 * Idempotent: completed history walks are detected, canonical values are fixed targets, and
 * already-current contacts/events are not updated.
 * Org-agnostic: records are resolved by the exact names in data/*.json, never by hardcoded Id.
 *
 * Run: sf apex run --file scripts/trigger-opp-history.apex --target-org <alias>
 */
System.debug('== trigger-opp-history: start ==');

final String ANCHOR_NAME = 'Joja Corporation - Warehouse Automation Platform';
final String RENEWAL_NAME = 'Joja Corporation - Membership Renewal FY27';
final Decimal RENEWAL_TARGET = 91000;

// Exact cardinality is part of the fixture contract. Duplicate imports must fail loudly.
List<Opportunity> mains = [
    SELECT Id, StageName, Probability, Amount
    FROM Opportunity
    WHERE Name = :ANCHOR_NAME
];
System.assertEquals(1, mains.size(), 'Expected exactly one canonical warehouse opportunity');
Opportunity anchor = mains[0];

// Walk the anchor through realistic snapshots exactly once so history-reading flows have rows.
List<String> stageWalk = new List<String>{
    'Qualification', 'Needs Analysis', 'Value Proposition',
    'Proposal/Price Quote', 'Negotiation/Review'
};
List<Decimal> amountWalk = new List<Decimal>{200000, 210000, 225000, 240000, 250000};
List<Decimal> probabilityWalk = new List<Decimal>{10, 20, 50, 75, 80};
Set<String> intermediateStages = new Set<String>(stageWalk);
intermediateStages.remove('Negotiation/Review');
Boolean alreadyWalked = ![
    SELECT Id
    FROM OpportunityHistory
    WHERE OpportunityId = :anchor.Id AND StageName IN :intermediateStages
    LIMIT 1
].isEmpty();
if (!alreadyWalked) {
    for (Integer i = 0; i < stageWalk.size(); i++) {
        anchor.StageName = stageWalk[i];
        anchor.Amount = amountWalk[i];
        anchor.Probability = probabilityWalk[i];
        update anchor;
    }
    System.debug('Wrote ' + stageWalk.size() + ' warehouse history snapshots.');
} else if (
    anchor.StageName != 'Negotiation/Review' ||
    anchor.Amount != 250000 ||
    anchor.Probability != 80
) {
    anchor.StageName = 'Negotiation/Review';
    anchor.Amount = 250000;
    anchor.Probability = 80;
    update anchor;
}

// Keep the loaded value and the live invariant at $91k while ensuring one recent history row.
List<Opportunity> renewals = [
    SELECT Id, StageName, Probability, Amount
    FROM Opportunity
    WHERE Name = :RENEWAL_NAME
];
System.assertEquals(1, renewals.size(), 'Expected exactly one canonical renewal opportunity');
Opportunity renewal = renewals[0];
System.assertEquals('Value Proposition', renewal.StageName, 'Unexpected renewal stage');
System.assertEquals(60, renewal.Probability, 'Unexpected renewal probability');
Boolean renewalHistoryPresent = ![
    SELECT Id
    FROM OpportunityHistory
    WHERE OpportunityId = :renewal.Id AND Amount = :RENEWAL_TARGET
    LIMIT 1
].isEmpty();
if (renewal.Amount != RENEWAL_TARGET) {
    renewal.Amount = RENEWAL_TARGET;
    update renewal;
} else if (!renewalHistoryPresent) {
    renewal.Amount = 90000;
    update renewal;
    renewal.Amount = RENEWAL_TARGET;
    update renewal;
}

// Reconcile free-text stakeholder facts with their exact OpportunityContactRole semantics.
List<Contact> morrises = [
    SELECT Id, Title, Description
    FROM Contact
    WHERE FirstName = 'Morris' AND LastName = 'Grey'
      AND Account.Name = 'Joja Corporation'
];
List<Contact> lewises = [
    SELECT Id, Title, Description
    FROM Contact
    WHERE FirstName = 'Lewis' AND LastName = 'Thornton'
      AND Account.Name = 'Joja Corporation'
];
System.assertEquals(1, morrises.size(), 'Expected exactly one Morris Grey at Joja');
System.assertEquals(1, lewises.size(), 'Expected exactly one Lewis Thornton at Joja');
Contact morris = morrises[0];
Contact lewis = lewises[0];
System.assertEquals('Regional Manager', morris.Title, 'Unexpected Morris title');
System.assertEquals('Chief Financial Officer', lewis.Title, 'Unexpected Lewis title');
Set<String> safeMorrisDescriptions = new Set<String>{
    'Economic buyer and internal champion at Joja Corporation.',
    'Primary decision maker and internal champion at Joja Corporation.'
};
Set<String> safeLewisDescriptions = new Set<String>{
    'Financial approver at Joja Corporation.',
    'Economic buyer and financial approver at Joja Corporation.'
};
System.assert(safeMorrisDescriptions.contains(morris.Description), 'Unexpected Morris description');
System.assert(safeLewisDescriptions.contains(lewis.Description), 'Unexpected Lewis description');
List<Contact> contactsToUpdate = new List<Contact>();
if (morris.Description != 'Primary decision maker and internal champion at Joja Corporation.') {
    morris.Description = 'Primary decision maker and internal champion at Joja Corporation.';
    contactsToUpdate.add(morris);
}
if (lewis.Description != 'Economic buyer and financial approver at Joja Corporation.') {
    lewis.Description = 'Economic buyer and financial approver at Joja Corporation.';
    contactsToUpdate.add(lewis);
}
if (!contactsToUpdate.isEmpty()) update contactsToUpdate;

// Canonical event schedule: Wednesday 10:00 PT and Friday 09:00 PT of the current PT week.
String pacificDate = System.now().format('yyyy-MM-dd', 'America/Los_Angeles');
Date pacificToday = Date.valueOf(pacificDate);
Date mondayAnchor = Date.newInstance(2000, 1, 3); // Known Monday.
Integer weekdayOffset = Math.mod(mondayAnchor.daysBetween(pacificToday), 7);
Date currentMonday = pacificToday.addDays(-weekdayOffset);
TimeZone pacific = TimeZone.getTimeZone('America/Los_Angeles');

Datetime qbrWallClock = Datetime.newInstanceGMT(
    currentMonday.addDays(2), Time.newInstance(10, 0, 0, 0));
Datetime qbrStart = qbrWallClock.addSeconds(-(pacific.getOffset(qbrWallClock) / 1000));
Datetime followupWallClock = Datetime.newInstanceGMT(
    currentMonday.addDays(4), Time.newInstance(9, 0, 0, 0));
Datetime followupStart = followupWallClock.addSeconds(
    -(pacific.getOffset(followupWallClock) / 1000));

Set<String> canonicalSubjects = new Set<String>{'Joja QBR', 'Follow-up with Morris'};
List<Event> eventRows = [
    SELECT Id, Subject, StartDateTime, EndDateTime, Location, WhatId, WhoId, OwnerId
    FROM Event
    WHERE OwnerId = :UserInfo.getUserId() AND Subject IN :canonicalSubjects
];
Map<String, Event> eventsBySubject = new Map<String, Event>();
for (Event row : eventRows) {
    System.assert(!eventsBySubject.containsKey(row.Subject), 'Duplicate canonical event: ' + row.Subject);
    eventsBySubject.put(row.Subject, row);
}
System.assertEquals(2, eventsBySubject.size(), 'Expected exactly two canonical current-user events');
Event qbr = eventsBySubject.get('Joja QBR');
Event followup = eventsBySubject.get('Follow-up with Morris');
System.assertEquals(anchor.Id, qbr.WhatId, 'Joja QBR must relate to the warehouse opportunity');
System.assertEquals(morris.Id, qbr.WhoId, 'Joja QBR must relate to Morris');
System.assertEquals(anchor.Id, followup.WhatId, 'Follow-up must relate to the warehouse opportunity');
System.assertEquals(morris.Id, followup.WhoId, 'Follow-up must relate to Morris');

List<Event> eventsToUpdate = new List<Event>();
if (
    qbr.StartDateTime != qbrStart ||
    qbr.EndDateTime != qbrStart.addMinutes(60) ||
    qbr.Location != 'Zoom'
) {
    qbr.StartDateTime = qbrStart;
    qbr.EndDateTime = qbrStart.addMinutes(60);
    qbr.Location = 'Zoom';
    eventsToUpdate.add(qbr);
}
if (
    followup.StartDateTime != followupStart ||
    followup.EndDateTime != followupStart.addMinutes(30) ||
    followup.Location != 'Phone'
) {
    followup.StartDateTime = followupStart;
    followup.EndDateTime = followupStart.addMinutes(30);
    followup.Location = 'Phone';
    eventsToUpdate.add(followup);
}
if (!eventsToUpdate.isEmpty()) update eventsToUpdate;

// Reserved weekly-wrap and exact call-prep fixtures. These are intentionally
// explicit setup data: nothing else mutates them.
List<Account> jojaAccounts = [SELECT Id FROM Account WHERE Name = 'Joja Corporation'];
System.assertEquals(1, jojaAccounts.size(), 'Expected exactly one Joja Corporation');
Id jojaAccountId = jojaAccounts[0].Id;
Map<String, Opportunity> weeklyByName = new Map<String, Opportunity>();
Set<String> staticWeeklyNames = new Set<String>{
    'H360 Eval Weekly Won', 'H360 Eval Weekly Lost', 'H360 Eval Weekly Touched',
    'H360 Eval Weekly Closing Next Week'
};
for (Opportunity row : [
    SELECT Id, Name, AccountId, OwnerId, StageName, Amount, CloseDate
    FROM Opportunity WHERE Name IN :staticWeeklyNames
]) {
    System.assert(!weeklyByName.containsKey(row.Name), 'Duplicate reserved weekly opportunity: ' + row.Name);
    weeklyByName.put(row.Name, row);
}
Map<String, Map<String, Object>> weeklyWanted = new Map<String, Map<String, Object>>{
    'H360 Eval Weekly Won' => new Map<String, Object>{'StageName' => 'Closed Won', 'Amount' => 111000, 'CloseDate' => currentMonday},
    'H360 Eval Weekly Lost' => new Map<String, Object>{'StageName' => 'Closed Lost', 'Amount' => 43000, 'CloseDate' => currentMonday.addDays(1)},
    'H360 Eval Weekly Touched' => new Map<String, Object>{'StageName' => 'Proposal/Price Quote', 'Amount' => 125000, 'CloseDate' => currentMonday.addDays(4)},
    'H360 Eval Weekly Closing Next Week' => new Map<String, Object>{'StageName' => 'Negotiation/Review', 'Amount' => 98000, 'CloseDate' => currentMonday.addDays(7)}
};
List<Opportunity> weeklyUpserts = new List<Opportunity>();
for (String name : staticWeeklyNames) {
    Map<String, Object> wanted = weeklyWanted.get(name);
    Opportunity row = weeklyByName.get(name);
    if (row == null) {
        weeklyUpserts.add(new Opportunity(Name = name, AccountId = jojaAccountId, OwnerId = UserInfo.getUserId(),
            StageName = (String) wanted.get('StageName'), Amount = (Decimal) wanted.get('Amount'),
            CloseDate = (Date) wanted.get('CloseDate')));
    } else {
        System.assertEquals(jojaAccountId, row.AccountId, 'Reserved weekly opportunity has unexpected account');
        System.assertEquals(UserInfo.getUserId(), row.OwnerId, 'Reserved weekly opportunity has unexpected owner');
        if (row.StageName != (String) wanted.get('StageName') || row.Amount != (Decimal) wanted.get('Amount') || row.CloseDate != (Date) wanted.get('CloseDate')) {
            row.StageName = (String) wanted.get('StageName');
            row.Amount = (Decimal) wanted.get('Amount');
            row.CloseDate = (Date) wanted.get('CloseDate');
            weeklyUpserts.add(row);
        }
    }
}
if (!weeklyUpserts.isEmpty()) upsert weeklyUpserts;

String weeklyNewName = 'H360 Eval Weekly New ' + String.valueOf(currentMonday);
List<Opportunity> weeklyNewRows = [
    SELECT Id, AccountId, OwnerId, StageName, Amount, CloseDate
    FROM Opportunity WHERE Name = :weeklyNewName
];
System.assert(weeklyNewRows.size() <= 1, 'Duplicate week-keyed weekly new opportunity');
if (weeklyNewRows.isEmpty()) {
    insert new Opportunity(Name = weeklyNewName, AccountId = jojaAccountId, OwnerId = UserInfo.getUserId(),
        StageName = 'Prospecting', Amount = 72000, CloseDate = currentMonday.addDays(5));
} else {
    Opportunity weeklyNew = weeklyNewRows[0];
    System.assertEquals(jojaAccountId, weeklyNew.AccountId, 'Weekly new opportunity has unexpected account');
    System.assertEquals(UserInfo.getUserId(), weeklyNew.OwnerId, 'Weekly new opportunity has unexpected owner');
    System.assertEquals('Prospecting', weeklyNew.StageName, 'Weekly new opportunity has unexpected stage');
    System.assertEquals(72000, weeklyNew.Amount, 'Weekly new opportunity has unexpected amount');
}

Integer daysUntilTuesday = Math.mod(1 - weekdayOffset + 7, 7);
if (daysUntilTuesday == 0) daysUntilTuesday = 7;
Datetime callPrepStart = Datetime.newInstanceGMT(currentMonday.addDays(weekdayOffset + daysUntilTuesday), Time.newInstance(10, 0, 0, 0));
callPrepStart = callPrepStart.addSeconds(-(pacific.getOffset(callPrepStart) / 1000));
Datetime weeklyReviewStart = Datetime.newInstanceGMT(currentMonday.addDays(3), Time.newInstance(14, 0, 0, 0));
weeklyReviewStart = weeklyReviewStart.addSeconds(-(pacific.getOffset(weeklyReviewStart) / 1000));
Datetime weeklyPlanStart = Datetime.newInstanceGMT(currentMonday.addDays(7), Time.newInstance(9, 0, 0, 0));
weeklyPlanStart = weeklyPlanStart.addSeconds(-(pacific.getOffset(weeklyPlanStart) / 1000));
Map<String, Event> reservedEvents = new Map<String, Event>();
Set<String> reservedSubjects = new Set<String>{
    'Joja — Warehouse Automation proposal review', 'H360 Eval Weekly Customer Review', 'H360 Eval Weekly Monday Plan'
};
for (Event row : [SELECT Id, Subject, StartDateTime, EndDateTime, Location, WhatId, WhoId, OwnerId FROM Event WHERE Subject IN :reservedSubjects]) {
    System.assert(!reservedEvents.containsKey(row.Subject), 'Duplicate reserved Event: ' + row.Subject);
    System.assertEquals(UserInfo.getUserId(), row.OwnerId, 'Wrong-owner reserved Event: ' + row.Subject);
    reservedEvents.put(row.Subject, row);
}
Map<String, Map<String, Object>> reservedEventWanted = new Map<String, Map<String, Object>>{
    'Joja — Warehouse Automation proposal review' => new Map<String, Object>{'Start' => callPrepStart, 'Minutes' => 60, 'Location' => 'Zoom', 'WhatId' => anchor.Id, 'WhoId' => lewis.Id},
    'H360 Eval Weekly Customer Review' => new Map<String, Object>{'Start' => weeklyReviewStart, 'Minutes' => 30, 'Location' => 'Zoom', 'WhatId' => jojaAccountId, 'WhoId' => lewis.Id},
    'H360 Eval Weekly Monday Plan' => new Map<String, Object>{'Start' => weeklyPlanStart, 'Minutes' => 30, 'Location' => 'Zoom', 'WhatId' => jojaAccountId, 'WhoId' => lewis.Id}
};
List<Event> reservedEventUpserts = new List<Event>();
for (String subject : reservedSubjects) {
    Map<String, Object> wanted = reservedEventWanted.get(subject);
    Datetime startAt = (Datetime) wanted.get('Start');
    Event row = reservedEvents.get(subject);
    if (row == null) {
        reservedEventUpserts.add(new Event(Subject = subject, OwnerId = UserInfo.getUserId(), WhatId = (Id) wanted.get('WhatId'), WhoId = (Id) wanted.get('WhoId'), StartDateTime = startAt, EndDateTime = startAt.addMinutes((Integer) wanted.get('Minutes')), Location = (String) wanted.get('Location')));
    } else {
        System.assertEquals(UserInfo.getUserId(), row.OwnerId, 'Reserved Event has unexpected owner');
        if (row.StartDateTime != startAt || row.EndDateTime != startAt.addMinutes((Integer) wanted.get('Minutes')) || row.Location != (String) wanted.get('Location') || row.WhatId != (Id) wanted.get('WhatId') || row.WhoId != (Id) wanted.get('WhoId')) {
            row.StartDateTime = startAt;
            row.EndDateTime = startAt.addMinutes((Integer) wanted.get('Minutes'));
            row.Location = (String) wanted.get('Location');
            row.WhatId = (Id) wanted.get('WhatId');
            row.WhoId = (Id) wanted.get('WhoId');
            reservedEventUpserts.add(row);
        }
    }
}
if (!reservedEventUpserts.isEmpty()) upsert reservedEventUpserts;

// Postconditions make setup itself fail if Salesforce did not persist the exact fixture contract.
anchor = [SELECT Id, StageName, Probability, Amount FROM Opportunity WHERE Id = :anchor.Id];
renewal = [SELECT Id, StageName, Probability, Amount FROM Opportunity WHERE Id = :renewal.Id];
qbr = [SELECT Id, StartDateTime, EndDateTime, Location, WhatId, WhoId, OwnerId FROM Event WHERE Id = :qbr.Id];
followup = [SELECT Id, StartDateTime, EndDateTime, Location, WhatId, WhoId, OwnerId FROM Event WHERE Id = :followup.Id];
System.assertEquals('Negotiation/Review', anchor.StageName);
System.assertEquals(80, anchor.Probability);
System.assertEquals(250000, anchor.Amount);
System.assertEquals('Value Proposition', renewal.StageName);
System.assertEquals(60, renewal.Probability);
System.assertEquals(RENEWAL_TARGET, renewal.Amount);
System.assertEquals(qbrStart, qbr.StartDateTime);
System.assertEquals(qbrStart.addMinutes(60), qbr.EndDateTime);
System.assertEquals('Zoom', qbr.Location);
System.assertEquals(anchor.Id, qbr.WhatId);
System.assertEquals(morris.Id, qbr.WhoId);
System.assertEquals(UserInfo.getUserId(), qbr.OwnerId);
System.assertEquals(followupStart, followup.StartDateTime);
System.assertEquals(followupStart.addMinutes(30), followup.EndDateTime);
System.assertEquals('Phone', followup.Location);
System.assertEquals(anchor.Id, followup.WhatId);
System.assertEquals(morris.Id, followup.WhoId);
System.assertEquals(UserInfo.getUserId(), followup.OwnerId);

// Re-query every reserved row after all DML and prove the six live weekly-wrap
// roots. These checks intentionally use Salesforce week literals rather than
// inferred history, because the skill reads those roots directly.
System.assertEquals(1, [SELECT count() FROM Opportunity WHERE Name = 'H360 Eval Weekly Won' AND CloseDate = THIS_WEEK]);
System.assertEquals(1, [SELECT count() FROM Opportunity WHERE Name = 'H360 Eval Weekly Lost' AND CloseDate = THIS_WEEK]);
System.assertEquals(1, [SELECT count() FROM Opportunity WHERE Name = :weeklyNewName AND CreatedDate = THIS_WEEK]);
System.assertEquals(1, [SELECT count() FROM Opportunity WHERE Name = 'H360 Eval Weekly Touched' AND IsClosed = false AND LastModifiedDate = THIS_WEEK]);
System.assertEquals(1, [SELECT count() FROM Opportunity WHERE Name = 'H360 Eval Weekly Closing Next Week' AND CloseDate = NEXT_WEEK]);
List<Event> verifiedReservedEvents = [
    SELECT Id, Subject, StartDateTime, EndDateTime, Location, WhatId, WhoId, OwnerId
    FROM Event WHERE Subject IN :reservedSubjects
];
System.assertEquals(3, verifiedReservedEvents.size(), 'Expected exactly three reserved Events');
Map<String, Event> verifiedReservedBySubject = new Map<String, Event>();
for (Event row : verifiedReservedEvents) {
    System.assert(!verifiedReservedBySubject.containsKey(row.Subject), 'Duplicate reserved Event: ' + row.Subject);
    System.assertEquals(UserInfo.getUserId(), row.OwnerId, 'Wrong-owner reserved Event: ' + row.Subject);
    verifiedReservedBySubject.put(row.Subject, row);
}
Event verifiedCallPrep = verifiedReservedBySubject.get('Joja — Warehouse Automation proposal review');
System.assertEquals(callPrepStart, verifiedCallPrep.StartDateTime);
System.assertEquals(callPrepStart.addMinutes(60), verifiedCallPrep.EndDateTime);
System.assertEquals('Zoom', verifiedCallPrep.Location);
System.assertEquals(anchor.Id, verifiedCallPrep.WhatId);
System.assertEquals(lewis.Id, verifiedCallPrep.WhoId);
Event verifiedWeeklyReview = verifiedReservedBySubject.get('H360 Eval Weekly Customer Review');
System.assertEquals(weeklyReviewStart, verifiedWeeklyReview.StartDateTime);
System.assertEquals(weeklyReviewStart.addMinutes(30), verifiedWeeklyReview.EndDateTime);
System.assertEquals(jojaAccountId, verifiedWeeklyReview.WhatId);
System.assertEquals(lewis.Id, verifiedWeeklyReview.WhoId);
Event verifiedWeeklyPlan = verifiedReservedBySubject.get('H360 Eval Weekly Monday Plan');
System.assertEquals(weeklyPlanStart, verifiedWeeklyPlan.StartDateTime);
System.assertEquals(weeklyPlanStart.addMinutes(30), verifiedWeeklyPlan.EndDateTime);
System.assertEquals(jojaAccountId, verifiedWeeklyPlan.WhatId);
System.assertEquals(lewis.Id, verifiedWeeklyPlan.WhoId);
System.assertEquals(1, [SELECT count() FROM Event WHERE Subject = 'H360 Eval Weekly Customer Review' AND StartDateTime = THIS_WEEK]);
System.assertEquals(1, [SELECT count() FROM Event WHERE Subject = 'H360 Eval Weekly Monday Plan' AND StartDateTime = NEXT_WEEK]);

System.debug('== trigger-opp-history: done ==');
