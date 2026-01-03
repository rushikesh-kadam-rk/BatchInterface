public interface IBatchWorker {
    /**
     * @return The full SOQL query string.
     */
    String getQuery();

    /**
     * @param whereClause A string containing the filtering logic. 
     * Example: "Rating = 'Hot' AND Industry = 'Energy'"
     * The worker implementation is responsible for appending this to the base query.
     */
    void setWhereClause(String whereClause);

    /**
     * Execution logic for the scope.
     */
    void processRecords(List<SObject> scope);

    /**
     * Finish logic.
     */
    void onFinish(Database.BatchableContext bc);

    /**
     * Metadata DeveloperName for config lookup.
     */
    String getBatchName();

    /**
     * Chaining logic.
     */
    IBatchWorker getNextWorker();
}