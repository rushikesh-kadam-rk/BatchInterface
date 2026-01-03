public class WellMoGrossUniqueDecimalVolumeWorker implements IBatchWorker {

    // --- STATE VARIABLES ---
    private Boolean shouldChainNextJob;
    private Set<Id> wellIdSet;
    private Date startDate;
    private Date endDate;

    // --- CONSTRUCTORS ---

    // Primary Constructor
    public WellMoGrossUniqueDecimalVolumeWorker(
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

    // Default Constructor (Framework reflection)
    public WellMoGrossUniqueDecimalVolumeWorker() {
        this(true, null, null, null);
    }

    // --- FRAMEWORK METHODS ---

    public String getBatchName() {
        // Create a Batch_Configuration__mdt record with this name to control batch size (default was 250)
        return 'Well_Mo_Gross_Unique_Decimal_Vol'; 
    }

    public void setWhereClause(String whereClause) {
        // Optional hook
    }
    
    public void setQueryParams(Map<String, Object> params) {
        // Optional hook
    }

    // --- 1. DYNAMIC QUERY GENERATION ---
    public String getQuery() {
        // Base Query
        String query = 'SELECT Id, ' +
                       'Gas_Sold_Volume_Gross_Op_Rept_Locked__c, ' +
                       'NGL_Volume_Gross_Op_Reported_Locked__c, ' +
                       'Oil_Volume_Gross_Op_Reported_Locked__c ' +
                       'FROM Well_Month__c WHERE ';

        // 1. Date Filter (Converted to String Literals)
        // If dates are null, we might default or handle gracefully, 
        // but assuming they are passed as per original logic.
        String dateFilter = '';
        if (startDate != null && endDate != null) {
            dateFilter = 'Well_Month_Date__c >= ' + String.valueOf(startDate) + 
                         ' AND Well_Month_Date__c <= ' + String.valueOf(endDate) + ' AND ';
        }

        // 2. Lock Filter (Only process if at least one field is UNLOCKED)
        String lockFilter = '(Gas_Sold_Volume_Gross_Op_Rept_Locked__c = FALSE ' +
                            'OR NGL_Volume_Gross_Op_Reported_Locked__c = FALSE ' +
                            'OR Oil_Volume_Gross_Op_Reported_Locked__c = FALSE)';

        // 3. Main Logic
        if (wellIdSet != null && !wellIdSet.isEmpty()) {
            // Filter by specific Wells
            String idList = '(\'' + String.join(new List<Id>(wellIdSet), '\',\'') + '\')';
            query += 'Well__c IN ' + idList + ' AND ' + dateFilter + lockFilter;
        } else {
            // Filter by DLRS Flag
            query += 'Run_DLRS_Accruals__c = TRUE AND ' + dateFilter + lockFilter;
        }

        return query;
    }

    // --- 2. EXECUTE LOGIC ---
    public void processRecords(List<SObject> scope) {
        List<Well_Month__c> wmScope = (List<Well_Month__c>) scope;
        Set<Id> wellMonthIds = new Set<Id>();
        
        for (Well_Month__c wm : wmScope) {
            wellMonthIds.add(wm.Id);
        }

        // Query Child Payments (Safe to use bind variable here as it's local)
        List<Well_Payment__c> wellPayments = [
            SELECT Id, Well_Month__c, Product_Description_RWW__c, Volume_RWW_Gross__c,
                   Well_Month__r.Oil_Volume_Gross_Op_Reported_Locked__c,
                   Well_Month__r.NGL_Volume_Gross_Op_Reported_Locked__c,
                   Well_Month__r.Gas_Sold_Volume_Gross_Op_Rept_Locked__c
            FROM Well_Payment__c
            WHERE Well_Month__c IN :wellMonthIds
            AND Use_in_Well_Month_Summaries_DLRS__c = TRUE
            AND Product_Description_RWW__c IN ('Oil', 'Gas', 'NGL')
        ];

        // Grouping Structure: WellMonthId -> Product -> List of Volumes
        Map<Id, Map<String, List<Decimal>>> volumeGroups = new Map<Id, Map<String, List<Decimal>>>();

        for (Well_Payment__c payment : wellPayments) {
            Id wellMonthId = payment.Well_Month__c;
            String productType = payment.Product_Description_RWW__c;
            Decimal grossVolume = payment.Volume_RWW_Gross__c;

            // Check Locks specifically for the product type
            Boolean isLocked = false;
            if (productType == 'Oil' && payment.Well_Month__r.Oil_Volume_Gross_Op_Reported_Locked__c) isLocked = true;
            else if (productType == 'NGL' && payment.Well_Month__r.NGL_Volume_Gross_Op_Reported_Locked__c) isLocked = true;
            else if (productType == 'Gas' && payment.Well_Month__r.Gas_Sold_Volume_Gross_Op_Rept_Locked__c) isLocked = true;

            if (isLocked) continue;

            if (!volumeGroups.containsKey(wellMonthId)) {
                volumeGroups.put(wellMonthId, new Map<String, List<Decimal>>());
            }
            if (!volumeGroups.get(wellMonthId).containsKey(productType)) {
                volumeGroups.get(wellMonthId).put(productType, new List<Decimal>());
            }
            volumeGroups.get(wellMonthId).get(productType).add(grossVolume);
        }

        List<Well_Month__c> updates = new List<Well_Month__c>();

        for (Well_Month__c wm : wmScope) {
            Map<String, List<Decimal>> productVolumes = volumeGroups.get(wm.Id);
            
            Decimal oilSum = 0;
            Decimal gasSum = 0;
            Decimal nglSum = 0;

            if (productVolumes != null) {
                for (String productType : productVolumes.keySet()) {
                    List<Decimal> volumes = productVolumes.get(productType);

                    // --- LOGIC: Cancel out positive/negative pairs ---
                    Map<Decimal, Integer> posCount = new Map<Decimal, Integer>();
                    Map<Decimal, Integer> negCount = new Map<Decimal, Integer>();

                    for (Decimal volume : volumes) {
                        if (volume > 0) {
                            posCount.put(volume, posCount.containsKey(volume) ? posCount.get(volume) + 1 : 1);
                        } else {
                            negCount.put(volume, negCount.containsKey(volume) ? negCount.get(volume) + 1 : 1);
                        }
                    }

                    // Cancel pairs
                    for (Decimal posValue : new List<Decimal>(posCount.keySet())) {
                        Decimal negValue = -posValue;
                        if (negCount.containsKey(negValue)) {
                            Integer posQty = posCount.get(posValue);
                            Integer negQty = negCount.get(negValue);
                            Integer cancelPairs = Math.min(posQty, negQty);

                            posCount.put(posValue, posQty - cancelPairs);
                            negCount.put(negValue, negQty - cancelPairs);

                            if (posCount.get(posValue) == 0) posCount.remove(posValue);
                            if (negCount.get(negValue) == 0) negCount.remove(negValue);
                        }
                    }

                    // Reset counts to 1 (Unique Logic) - Original code sets count to 1 after cancellation
                    for (Decimal posValue : new List<Decimal>(posCount.keySet())) posCount.put(posValue, 1);
                    for (Decimal negValue : new List<Decimal>(negCount.keySet())) negCount.put(negValue, 1);

                    // Sum remaining
                    Decimal netSum = 0;
                    for (Decimal value : posCount.keySet()) netSum += value * posCount.get(value);
                    for (Decimal value : negCount.keySet()) netSum += value * negCount.get(value);

                    if (productType == 'Oil') oilSum = netSum;
                    else if (productType == 'Gas') gasSum = netSum;
                    else if (productType == 'NGL') nglSum = netSum;
                }
            }

            // Apply Updates (Respecting Locks)
            if (!wm.Oil_Volume_Gross_Op_Reported_Locked__c) wm.Oil_Volume_Gross_Op_Reported_Bbls__c = oilSum;
            if (!wm.Gas_Sold_Volume_Gross_Op_Rept_Locked__c) wm.Gas_Sold_Volume_Gross_Op_Reported_Mcf__c = gasSum;
            if (!wm.NGL_Volume_Gross_Op_Reported_Locked__c) wm.NGL_Volume_Gross_Op_Reported_Gals__c = nglSum;

            updates.add(wm);
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }

    // --- 3. FINISH LOGIC ---
    public void onFinish(Database.BatchableContext bc) {
        System.debug('Determine Unique Gross Volumes completed.');
    }

    // --- 4. CHAINING LOGIC ---
    public IBatchWorker getNextWorker() {
        if (shouldChainNextJob) {
            return new WellRecentWellMonthVolumeWorker(
                shouldChainNextJob,
                wellIdSet,
                startDate,
                endDate
            );
        }
        return null;
    }
}