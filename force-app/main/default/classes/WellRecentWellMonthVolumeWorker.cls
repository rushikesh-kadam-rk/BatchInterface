public class WellRecentWellMonthVolumeWorker implements IBatchWorker {

    // --- STATE VARIABLES ---
    private Boolean shouldChainNextJob;
    private Set<Id> wellIdSet;
    private Date startDate;
    private Date endDate;

    // --- CONSTRUCTORS ---

    // Primary Constructor
    public WellRecentWellMonthVolumeWorker(
        Boolean shouldChainNextJob,
        Set<Id> wellIdSet,
        Date startDate,
        Date endDate
    ) {
        this.shouldChainNextJob = (shouldChainNextJob == null) ? true : shouldChainNextJob;
        this.wellIdSet = wellIdSet;
        this.startDate = startDate;
        this.endDate = endDate;
    }

    // Default Constructor
    public WellRecentWellMonthVolumeWorker() {
        this(true, null, null, null);
    }

    // --- FRAMEWORK METHODS ---

    public String getBatchName() {
        // Matches DeveloperName in Batch_Configuration__mdt (was 'RecentWellMoVolume' group)
        return 'Recent_Well_Month_Volume_Job'; 
    }

    public void setWhereClause(String whereClause) {}
    public void setQueryParams(Map<String, Object> params) {}

    // --- 1. DYNAMIC QUERY GENERATION ---
    public String getQuery() {
        // Scenario A: Specific Wells & Dates
        if (wellIdSet != null && !wellIdSet.isEmpty() && startDate != null && endDate != null) {
            String idList = '(\'' + String.join(new List<Id>(wellIdSet), '\',\'') + '\')';
            String dateFilter = 'Production_Start_Date__c >= ' + String.valueOf(startDate) + 
                              ' AND Production_Start_Date__c <= ' + String.valueOf(endDate);
            
            return 'SELECT Id, Name FROM Well__c WHERE Id IN ' + idList + ' AND ' + dateFilter;
        }

        // Scenario B: Full Run (Wells with payments)
        return 'SELECT Id FROM Well__c WHERE Well_Payment_Count__c > 0';
    }

    // --- 2. EXECUTE LOGIC ---
    public void processRecords(List<SObject> scope) {
        List<Well__c> wellScope = (List<Well__c>) scope;
        if (wellScope.isEmpty()) return;

        Set<Id> parentIds = new Set<Id>();
        for (Well__c well : wellScope) {
            parentIds.add(well.Id);
        }

        // 1. Compute 12-month window
        Date today = Date.today();
        Date firstOfMonth = Date.newInstance(today.year(), today.month(), 1);
        // Logic from original class:
        Date startRange = firstOfMonth.addMonths(-11);
        Date endRange = firstOfMonth.addMonths(1).addDays(-1);
        Date systemDateThreshold = System.today().addMonths(-12);

        // 2. Query Related Well Months
        // Note: We can use bind variables here because this runs inside the worker's context
        List<Well_Month__c> wellMonthRecords = [
            SELECT Id, Well__c, Well_Month_Date__c,
                   Oil_Op_Reported_Decimal__c,
                   Gas_Sold_Op_Reported_Decimal__c,
                   NGL_Op_Reported_Decimal__c,
                   Working_Interest_Op_Reported__c
            FROM Well_Month__c
            WHERE Well__c IN :parentIds
            AND Well_Month_Date__c >= :startRange
            AND Well_Month_Date__c <= :endRange
            AND (Oil_Op_Reported_Decimal__c > 0
                 OR Gas_Sold_Op_Reported_Decimal__c > 0
                 OR NGL_Op_Reported_Decimal__c > 0
                 OR Working_Interest_Op_Reported__c > 0)
            AND Well_Month_Date__c >= :systemDateThreshold
            ORDER BY Well__c, Well_Month_Date__c DESC
        ];

        // 3. Group by Well
        Map<Id, List<Well_Month__c>> wellToMonthsMap = new Map<Id, List<Well_Month__c>>();
        for (Well_Month__c wm : wellMonthRecords) {
            if (!wellToMonthsMap.containsKey(wm.Well__c)) {
                wellToMonthsMap.put(wm.Well__c, new List<Well_Month__c>());
            }
            wellToMonthsMap.get(wm.Well__c).add(wm);
        }

        // 4. Determine Recent Records
        List<Well__c> updates = new List<Well__c>();
        
        // Iterate over scope to ensure we process even wells that might have no months (though loop won't run)
        // Better to iterate the map keys found.
        for (Id wellId : wellToMonthsMap.keySet()) {
            List<Well_Month__c> monthsForWell = wellToMonthsMap.get(wellId);
            Well__c parentWell = new Well__c(Id = wellId);

            Boolean gasUpdated = false;
            Boolean nglUpdated = false;
            Boolean oilUpdated = false;
            Boolean wiUpdated = false;

            // Loop through months (Sorted DESC by Date)
            for (Well_Month__c wm : monthsForWell) {
                // Find most recent GAS
                if (!gasUpdated && wm.Gas_Sold_Op_Reported_Decimal__c != null && wm.Gas_Sold_Op_Reported_Decimal__c > 0) {
                    parentWell.Gas_Recent_Well_Month__c = wm.Id;
                    gasUpdated = true;
                }
                // Find most recent NGL
                if (!nglUpdated && wm.NGL_Op_Reported_Decimal__c != null && wm.NGL_Op_Reported_Decimal__c > 0) {
                    parentWell.NGL_Recent_Well_Month__c = wm.Id;
                    nglUpdated = true;
                }
                // Find most recent OIL
                if (!oilUpdated && wm.Oil_Op_Reported_Decimal__c != null && wm.Oil_Op_Reported_Decimal__c > 0) {
                    parentWell.Oil_Recent_Well_Month__c = wm.Id;
                    oilUpdated = true;
                }
                // Find most recent WI
                if (!wiUpdated && wm.Working_Interest_Op_Reported__c != null && wm.Working_Interest_Op_Reported__c > 0) {
                    parentWell.Working_Interest_Recent_Well_Month__c = wm.Id;
                    wiUpdated = true;
                }

                // If all found, stop looking for this well
                if (gasUpdated && nglUpdated && oilUpdated && wiUpdated) {
                    break;
                }
            }
            updates.add(parentWell);
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }

    // --- 3. FINISH LOGIC ---
    public void onFinish(Database.BatchableContext bc) {
        // Logging or email logic if needed
    }

    // --- 4. CHAINING LOGIC ---
    public IBatchWorker getNextWorker() {
        if (shouldChainNextJob) {
            return new WellWecimalRollupWorker(
                shouldChainNextJob,
                wellIdSet,
                startDate,
                endDate
            );
        }
        return null;
    }
}