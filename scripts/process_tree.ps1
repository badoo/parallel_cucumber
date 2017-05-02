Function Get-ProcessChildren($P,$Depth=1)
{
    $procs | Where-Object {$_.ParentProcessId -eq $p.ProcessID -and $_.ParentProcessId -ne 0} | ForEach-Object {
        "{0} {1} {2} {3}" -f (" "*3*$Depth),$_.Name,$_.ProcessID,$_.ParentProcessId
        Get-ProcessChildren $_ (++$Depth)
        $Depth--
    }
}
Function Show-ProcessTree
{
    $filter = {-not (Get-Process -Id $_.ParentProcessId -ErrorAction SilentlyContinue) -or $_.ParentProcessId -eq 0}
    $procs = Get-WmiObject Win32_Process
    $top = $procs | Where-Object $filter | Sort-Object ProcessID
    foreach ($p in $top)
    {
        "{0} {1}" -f $p.Name, $p.ProcessID
        Get-ProcessChildren $p
    }
}

Show-ProcessTree