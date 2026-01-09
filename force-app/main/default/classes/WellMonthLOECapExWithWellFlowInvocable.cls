public with sharing class WellMonthLOECapExWithWellFlowInvocable {
  @InvocableMethod(
    label='Run WellMonthTotalLOECapEx Batch For Specific Wells'
    description='Runs the WellMonthTotalLOECapExBatch with an optional chaining flag.'
  )
  public static void runTotalLOWCapExBatch(List<BatchRequest> requests) {
    for (BatchRequest req : requests) {
      Boolean shouldChain = (req.shouldChainNextJob == null)
        ? false
        : req.shouldChainNextJob;
      List<Id> recordIds = req.wellIds != null ? req.wellIds : null;
      Set<id> wellIds = new Set<Id>(recordIds);
      Database.executeBatch(
        new WellMonthTotalLOECapExBatch(
          shouldChain,
          wellIds,
          req.startDate,
          req.endDate,
          null
        ),
        50
      );
    }
  }

  public class BatchRequest {
    @InvocableVariable(required=true label='Should Chain Next Job')
    public Boolean shouldChainNextJob;
    @InvocableVariable(required=true label='Well Record Ids')
    public List<Id> wellIds;
    @InvocableVariable(required=true label='Start Date')
    public Date startDate;
    @InvocableVariable(required=true label='End Date')
    public Date endDate;
  }
}
