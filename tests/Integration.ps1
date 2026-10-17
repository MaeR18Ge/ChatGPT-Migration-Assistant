param([string]$ProjectRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$testRoot=Join-Path (Join-Path $ProjectRoot 'work') ('integration-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$harness=Join-Path $testRoot 'engine';[IO.Directory]::CreateDirectory($harness)|Out-Null
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src') -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $harness $file.Name)}
$configPath=Join-Path $testRoot 'test-environment.json';$literal=$configPath.Replace("'","''")
$corePath=Join-Path $harness 'Migration.Core.psm1';$core=[IO.File]::ReadAllText($corePath)
# Dependency injection exists only in this disposable test copy. Shipping discovery is untouched.
$core=[regex]::Replace($core,'(?m)^function Get-StateRoot \{.*\}',("function Get-StateRoot { (Read-Json '"+$literal+"').StateRoot }"))
$catalog=@'
function Get-Catalog([switch]$IncludeMissing) { @((Read-Json '__CONFIG__').Entries) }
'@
$core=[regex]::Replace($core,'(?s)function Get-Catalog.*?(?=function Get-EntryStats)',($catalog.Replace('__CONFIG__',$literal)+"`n"))
[IO.File]::WriteAllText($corePath,$core,[Text.UTF8Encoding]::new($true))
Import-Module $corePath -Force
$environment=[pscustomobject]@{StateRoot=(Join-Path $testRoot 'state');Entries=@()};Save-Json $configPath $environment
$results=[Collections.Generic.List[object]]::new();$knownLinks=[Collections.Generic.List[string]]::new()
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Action){
 try{& $Action;$results.Add(@{Name=$Name;Passed=$true});Write-Output ('PASS '+$Name)}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function New-Fixture([string]$Name,[switch]$LongPath){
 $root=Join-Path $testRoot $Name;$source=Join-Path $root 'source';$destinationRoot=Join-Path $root 'target'
 [IO.Directory]::CreateDirectory($source)|Out-Null;[IO.Directory]::CreateDirectory($destinationRoot)|Out-Null
 [IO.Directory]::CreateDirectory((Join-Path $source 'empty'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $source 'data.txt'),'original-data')
 [IO.File]::WriteAllText((Join-Path $source 'readonly.idx'),'read-only-index')
 [IO.File]::SetAttributes((Join-Path $source 'readonly.idx'),[IO.FileAttributes]::ReadOnly)
 if($LongPath){$long=Join-Path $source ((('segment-'+('x'*30)+'\')*7)+'long.txt');[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([ChatGPTtMigration.Engine]::Long($long)))|Out-Null;[IO.File]::WriteAllText([ChatGPTtMigration.Engine]::Long($long),'long-path-data')}
 $entry=[pscustomobject]@{Id=$Name;Product='Fixture';Name=$Name;Source=$source;Suffix='Data';Default=$true;Linked=$false;Current=$source;Error='';Files=0;Bytes=[long]0}
 $environment.Entries=@($environment.Entries)+@($entry);Save-Json $configPath $environment
 $knownLinks.Add($source)
 [pscustomobject]@{Root=$root;Entry=$entry;TargetRoot=$destinationRoot;Destination=(Get-Destination $entry $destinationRoot)}
}
function New-TestRun($Fixture,[bool]$Keep=$true){$plan=New-Plan @($Fixture.Entry) $Fixture.TargetRoot $Keep $false $false;$run=New-Run $plan;[pscustomobject]@{Plan=$plan;Run=$run}}
function Run-Worker($Job,[string]$Mode='Migrate'){
 $worker=Join-Path $Job.Run 'engine\Worker.ps1'
 $p=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$worker+'"'),'-RunDirectory',('"'+$Job.Run+'"'),'-Mode',$Mode) -WorkingDirectory $Job.Run -WindowStyle Hidden -PassThru -Wait
 $status=Read-Json (Join-Path $Job.Run 'status.json')
 if($status.State-eq 'complete'-and $p.ExitCode-ne 0){throw ('Worker exit mismatch: '+$p.ExitCode)}
 return $status
}
function Install-ServiceSimulation($Job,[string]$TracePath,[switch]$FailCopy){
 $path=Join-Path $Job.Run 'engine\Worker.ps1';$worker=[IO.File]::ReadAllText($path)
 $simulation=@'
Add-Type -AssemblyName System.ServiceProcess
$script:FakeService=[pscustomobject]@{Name='CodexSandboxService.OpenAI.Codex';Status='Running'}
$script:ServiceTrace=[pscustomobject]@{Stops=0;Starts=0;Status='Running'}
$script:FakeService|Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
$script:FakeService|Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($Wanted,$Timeout) if([string]$this.Status-ne [string]$Wanted){throw 'Simulated service status mismatch.'}}
function Get-Service {param([string]$Name) $script:FakeService}
function Stop-Service {param([string]$Name) $script:FakeService.Status='Stopped';$script:ServiceTrace.Stops++;$script:ServiceTrace.Status='Stopped';Save-Json '__TRACE__' $script:ServiceTrace}
function Start-Service {param([string]$Name) $script:FakeService.Status='Running';$script:ServiceTrace.Starts++;$script:ServiceTrace.Status='Running';Save-Json '__TRACE__' $script:ServiceTrace}
function Get-TestLockOwners {param($Guard) @([pscustomobject]@{Service='CodexSandboxService.OpenAI.Codex';ProcessId=1;Name='Simulated service'})}
'@
 $worker=$worker.Replace('function Release-KnownLocks {',($simulation.Replace('__TRACE__',$TracePath.Replace("'","''"))+"`nfunction Release-KnownLocks {"))
 $worker=$worker.Replace('[ChatGPTtMigration.Locks]::Query($guard)','(Get-TestLockOwners $guard)').Replace('[ChatGPTtMigration.Locks]::CheckServicePermission($name)','$null')
 if($FailCopy){$worker=$worker.Replace('[ChatGPTtMigration.Engine]::Copy($Entry.Source,$Entry.Destination,$progress)',"throw 'Injected test copy failure'")}
 [IO.File]::WriteAllText($path,$worker,[Text.UTF8Encoding]::new($true))
}
try{
 Case 'migrate_long_paths_readonly_empty_dirs_and_free_original' {
  $f=New-Fixture 'long-path' -LongPath;$job=New-TestRun $f $false;$status=Run-Worker $job
  Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 9)
  Assert (Test-Link $f.Entry.Source $f.Destination) 'Original path is not a junction.'
  Assert (-not(Test-Path -LiteralPath (Get-BackupPath $f.Entry $job.Plan.Id))) 'Original backup was not cleaned.'
  Assert ([IO.File]::GetAttributes((Join-Path $f.Destination 'readonly.idx')) -band [IO.FileAttributes]::ReadOnly) 'Read-only attribute was lost.'
  $null=[ChatGPTtMigration.Engine]::Verify($f.Entry.Source,$f.Destination,$null)
 }
 Case 'rollback_keeps_post_migration_edits_and_target_data' {
  $f=New-Fixture 'rollback';$job=New-TestRun $f;$status=Run-Worker $job;Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 8)
  [IO.File]::WriteAllText((Join-Path $f.Destination 'latest.txt'),'new-data-after-migration')
  $status=Run-Worker $job 'Rollback';Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 8)
  Assert (-not [ChatGPTtMigration.Engine]::IsLink($f.Entry.Source)) 'Rollback left the source as a link.'
  Assert ([IO.File]::ReadAllText((Join-Path $f.Entry.Source 'latest.txt'))-eq 'new-data-after-migration') 'Latest changes were lost.'
  Assert ([IO.File]::Exists((Join-Path $f.Destination 'latest.txt'))) 'Target was unexpectedly deleted.'
  $status=Run-Worker $job 'Cleanup';Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 8)
  Assert (-not(Test-Path -LiteralPath (Get-BackupPath $f.Entry $job.Plan.Id))) 'Owned backup cleanup failed.'
 }
 Case 'resume_preserves_partial_copy_and_removes_stale_files_from_final_target' {
  $f=New-Fixture 'resume';$job=New-TestRun $f
  Set-PrivateDirectory $f.Destination
  [IO.File]::WriteAllText((Join-Path $f.Destination 'stale.db'),'stale')
  $journal=Read-Json (Join-Path $job.Run 'journal.json')
  $journal.Entries=@([pscustomobject]@{Id=$f.Entry.Id;Source=$f.Entry.Source;Destination=$f.Destination;Backup=(Get-BackupPath $f.Entry $job.Plan.Id);RestoreTemp=(Get-BackupPath $f.Entry $job.Plan.Id 'restore');Claimed=$true;Phase='copying';Bytes=0;Verified=$false;BackupRemoved=$false;Rollback=$false;RollbackVerified=$false;IncompleteCopies=@()})
  Save-Json (Join-Path $job.Run 'journal.json') $journal
  $status=Run-Worker $job;Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 9)
  Assert (-not(Test-Path -LiteralPath (Join-Path $f.Destination 'stale.db'))) 'Stale DB was mixed into the final copy.'
  $journal=Read-Json (Join-Path $job.Run 'journal.json');Assert (@($journal.Entries[0].IncompleteCopies).Count-eq 1) 'Incomplete copy was not preserved.'
 }
 Case 'recover_interrupted_switch_without_missing_original_path' {
  $f=New-Fixture 'recover';$job=New-TestRun $f;$status=Run-Worker $job;Assert ($status.State-eq 'complete') 'Initial fixture migration failed.'
  $journal=Read-Json (Join-Path $job.Run 'journal.json');$journal.Entries[0].Verified=$false;$journal.Entries[0].Phase='switching'
  [IO.Directory]::Delete($f.Entry.Source) # Simulate a crash between renaming source and creating its junction.
  Save-Json (Join-Path $job.Run 'journal.json') $journal
  $status=Run-Worker $job;Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 9)
  Assert (Test-Link $f.Entry.Source $f.Destination) 'Interrupted switch was not recovered.'
 }
 Case 'reject_nonempty_destination_and_path_cycle' {
  $f=New-Fixture 'nonempty';[IO.Directory]::CreateDirectory($f.Destination)|Out-Null;[IO.File]::WriteAllText((Join-Path $f.Destination 'keep.txt'),'do-not-touch')
  $refused=$false;try{$null=New-Plan @($f.Entry) $f.TargetRoot}catch{$refused=$true};Assert $refused 'Nonempty destination was accepted.'
  Assert ([IO.File]::ReadAllText((Join-Path $f.Destination 'keep.txt'))-eq 'do-not-touch') 'Existing target data changed.'
  $refused=$false;try{$null=New-Plan @($f.Entry) $f.Entry.Source}catch{$refused=$true};Assert $refused 'Target/source cycle was accepted.'
 }
 Case 'reject_nested_link_without_touching_its_target' {
  $f=New-Fixture 'nested-link';$outside=Join-Path $f.Root 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null;[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'keep')
  $link=Join-Path $f.Entry.Source 'linked';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null;$knownLinks.Add($link)
  $refused=$false;try{$null=Get-EntryStats $f.Entry}catch{$refused=$true};Assert $refused 'Nested link was followed.'
  Assert ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt'))-eq 'keep') 'External target was modified.'
  [IO.Directory]::Delete($link)
 }
 Case 'unknown_live_guard_lock_preserves_original' {
  $f=New-Fixture 'locked';$guard=Join-Path $f.Entry.Source 'unknown.guard';[IO.File]::WriteAllBytes($guard,[byte[]]@());$job=New-TestRun $f
  $handle=[IO.File]::Open($guard,'Open','ReadWrite','ReadWrite')
  try{$status=Run-Worker $job;Assert ($status.State-eq 'error') 'Unknown live guard lock was not rejected.';Assert (-not [ChatGPTtMigration.Engine]::IsLink($f.Entry.Source)) 'Locked source was switched.'}finally{$handle.Dispose()}
 }
 Case 'safe_cancel_before_copy' {
  $f=New-Fixture 'cancel';$job=New-TestRun $f;[IO.File]::WriteAllText((Join-Path $job.Run 'cancel.request'),'cancel')
  $status=Run-Worker $job;Assert ($status.State-eq 'cancelled') ($status|ConvertTo-Json -Depth 6)
  Assert (-not [ChatGPTtMigration.Engine]::IsLink($f.Entry.Source)) 'Cancelled source was switched.'
 }
 Case 'concurrent_resource_lock_blocks_another_job_before_changes' {
  $f=New-Fixture 'concurrent';$job=New-TestRun $f;$lockRoot=Join-Path (Get-StateRoot) 'locks';Set-PrivateDirectory $lockRoot
  $resource=Get-ResourceLockPath 'source' $f.Entry.Source;$handle=[IO.File]::Open($resource,'OpenOrCreate','ReadWrite','None')
  try{$status=Run-Worker $job;Assert ($status.State-eq 'error') 'Concurrent source lock was ignored.';Assert (-not [ChatGPTtMigration.Engine]::IsLink($f.Entry.Source)) 'Busy source was changed.'}finally{$handle.Dispose()}
 }
 Case 'tampered_plan_cannot_redirect_migration' {
  $f=New-Fixture 'tamper';$job=New-TestRun $f;$plan=Read-Json (Join-Path $job.Run 'plan.json');$plan.Entries[0].Destination=Join-Path $f.Root 'unapproved';Save-Json (Join-Path $job.Run 'plan.json') $plan
  $status=Run-Worker $job;Assert ($status.State-eq 'error') 'Tampered destination was accepted.'
  Assert ([IO.File]::ReadAllText((Join-Path $f.Entry.Source 'data.txt'))-eq 'original-data') 'Source changed after invalid plan.'
 }
 Case 'classify_mcp_helper_separately_from_visible_application' {
  $p=[pscustomobject]@{Name='ChatCut.exe';ExecutablePath='X:\ChatCut\ChatCut.exe';CommandLine='"X:\ChatCut\ChatCut.exe" "X:\ChatCut\resources\app.asar\out\main\mcp\server.js"'}
  Assert (Get-ProcessClassification $p @('ChatCut') 0).CanStop 'Windowless MCP helper not recognized.'
  Assert (-not (Get-ProcessClassification $p @('ChatCut') 123).CanStop) 'Visible window would be automatically killed.'
  $p.CommandLine='"X:\ChatCut\ChatCut.exe"';Assert (-not (Get-ProcessClassification $p @('ChatCut') 0).CanStop) 'Tray application was treated as an MCP helper.'
 }
 Case 'status_write_is_complete_json' {
  $path=Join-Path $testRoot 'atomic.json';for($i=0;$i-lt 20;$i++){Save-Json $path @{Index=$i;Data=('x'*10000)};Assert ((Read-Json $path).Index-eq $i) 'Atomic JSON replacement failed.'}
 }
 Case 'protected_file_access_rules_remain_protected' {
  $f=New-Fixture 'protected-acl';$file=Join-Path $f.Entry.Source 'private.txt';[IO.File]::WriteAllText($file,'private-fixture')
  $acl=New-Object Security.AccessControl.FileSecurity;$acl.SetAccessRuleProtection($true,$false)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')))|Out-Null
  [ChatGPTtMigration.Engine]::SetDacl($file,$acl.GetSecurityDescriptorBinaryForm())
  $job=New-TestRun $f;$status=Run-Worker $job;Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 8)
  $copied=Get-Acl -LiteralPath (Join-Path $f.Destination 'private.txt')
  Assert $copied.AreAccessRulesProtected 'Protected access rules became inherited.'
  Assert (@($copied.Access|Where-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value-ne $sid.Value}).Count-eq 0) 'Protected file gained additional readers.'
 }
 Case 'service_restored_after_success_using_simulated_service' {
  $f=New-Fixture 'service-success';[IO.File]::WriteAllBytes((Join-Path $f.Entry.Source 'fixture.guard'),[byte[]]@())
  $job=New-TestRun $f;$plan=Read-Json (Join-Path $job.Run 'plan.json');$plan.ManageServices=$true;Save-Json (Join-Path $job.Run 'plan.json') $plan
  $trace=Join-Path $f.Root 'service-trace.json';Install-ServiceSimulation $job $trace
  $status=Run-Worker $job;Assert ($status.State-eq 'complete') ($status|ConvertTo-Json -Depth 9)
  $state=Read-Json $trace;Assert ($state.Stops-eq 1-and $state.Starts-eq 1-and $state.Status-eq 'Running') 'Simulated service was not restored.'
  $journal=Read-Json (Join-Path $job.Run 'journal.json');Assert (@($journal.Services).Count-eq 0) 'Service restoration intent was not cleared.'
 }
 Case 'service_restored_after_failure_using_simulated_service' {
  $f=New-Fixture 'service-failure';[IO.File]::WriteAllBytes((Join-Path $f.Entry.Source 'fixture.guard'),[byte[]]@())
  $job=New-TestRun $f;$plan=Read-Json (Join-Path $job.Run 'plan.json');$plan.ManageServices=$true;Save-Json (Join-Path $job.Run 'plan.json') $plan
  $trace=Join-Path $f.Root 'service-trace.json';Install-ServiceSimulation $job $trace -FailCopy
  $status=Run-Worker $job;Assert ($status.State-eq 'partial_error') ($status|ConvertTo-Json -Depth 9)
  $state=Read-Json $trace;Assert ($state.Stops-eq 1-and $state.Starts-eq 1-and $state.Status-eq 'Running') 'Failed migration left the simulated service stopped.'
  Assert (-not [ChatGPTtMigration.Engine]::IsLink($f.Entry.Source)) 'Failed copy switched the source.'
 }
 Case 'independent_scheduled_task_and_progress_interface' {
  $f=New-Fixture 'independent';$job=New-TestRun $f
  $taskName='ChatGPTt-Test-'+[guid]::NewGuid().ToString('N');$probe=Join-Path $testRoot 'scheduler-probe.ps1';$resultPath=Join-Path $testRoot 'scheduler-result.json'
  $probeText=@'
$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)
$parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.ParentProcessId)
@{Id=$PID;Parent=$parent.Name}|ConvertTo-Json|Set-Content -LiteralPath '__RESULT__' -Encoding UTF8
'@
  [IO.File]::WriteAllText($probe,$probeText.Replace('__RESULT__',$resultPath.Replace("'","''")),[Text.UTF8Encoding]::new($true))
  try{
   $null=Register-IndependentTask $probe '' $testRoot $taskName
   $deadline=(Get-Date).AddSeconds(15);while(-not(Test-Path -LiteralPath $resultPath)){if((Get-Date)-gt $deadline){throw 'Independent task did not run.'};Start-Sleep -Milliseconds 250}
   $result=Read-Json $resultPath;Assert ($result.Parent-notmatch 'ChatGPT|Codex|ChatCut') 'Worker was parented by the application being closed.'
  }finally{$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$scheduler.GetFolder('\').DeleteTask($taskName,0)}
  $out=Join-Path $testRoot 'progress-ui.txt';$err=Join-Path $testRoot 'progress-ui-error.txt'
  $p=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $job.Run 'engine\Progress.ps1')+'"'),'-RunDirectory',('"'+$job.Run+'"'),'-SelfTest') -WorkingDirectory $job.Run -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru
  Assert ($p.ExitCode-eq 0) ([IO.File]::ReadAllText($err))
  Assert ([IO.File]::ReadAllText($out)-match 'PROGRESS_UI_TEST_PASSED') 'Progress view test did not finish.'
 }
}finally{
 $failed=@($results.ToArray()|Where-Object {-not $_.Passed})
 $report=@{Runtime=$PSVersionTable.PSVersion.ToString();Passed=$results.Count-$failed.Count;Failed=$failed.Count;Cases=@($results.ToArray());Time=(Get-Date).ToString('o')}
 $output=Join-Path (Join-Path $ProjectRoot 'dist') 'test-results.json';Save-Json $output $report
 foreach($path in $knownLinks){if(Test-Path -LiteralPath $path){if([ChatGPTtMigration.Engine]::IsLink($path)){[IO.Directory]::Delete($path)}}}
 $expectedParent=[ChatGPTtMigration.Engine]::Canonical((Join-Path $ProjectRoot 'work'))
 if([ChatGPTtMigration.Engine]::Canonical([IO.Path]::GetDirectoryName($testRoot))-ine $expectedParent){throw 'Test cleanup containment check failed.'}
 if($failed.Count-eq 0){[ChatGPTtMigration.Engine]::DeleteTree($testRoot)}else{Write-Output ('Failed test fixtures retained: '+$testRoot)}
}
if($failed.Count){exit 1}
