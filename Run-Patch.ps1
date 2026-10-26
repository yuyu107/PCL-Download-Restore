param([string]$Target = '', [ValidateSet('Apply','Check','Restore')][string]$Mode = 'Apply')
$ErrorActionPreference = 'Stop'
function Hash-Bytes([byte[]]$Data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Data))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Clear() }
}
function Atomic-Write([string]$File,[byte[]]$Data) {
    $temp = $File + '.tmp-' + [Guid]::NewGuid().ToString('N')
    $swap = $temp + '.previous'
    try {
        [IO.File]::WriteAllBytes($temp,$Data)
        if ((Hash-Bytes ([IO.File]::ReadAllBytes($temp))) -ne (Hash-Bytes $Data)) { throw '临时文件校验失败。' }
        if ([IO.File]::Exists($File)) { [IO.File]::Replace($temp,$File,$swap) }
        else { [IO.File]::Move($temp,$File) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($swap)) { [IO.File]::Delete($swap) }
    }
}
try {
    $base = Split-Path -Parent $MyInvocation.MyCommand.Path
    Write-Host 'PCL 离线通用补丁 r12（内嵌核心版）'
    Write-Host ('当前脚本：' + $MyInvocation.MyCommand.Path)
    if ([string]::IsNullOrEmpty($Target)) { $Target = Join-Path $base 'Plain Craft Launcher 2.exe' }
    $Target = (Resolve-Path -LiteralPath $Target).ProviderPath
    [byte[]]$current = [IO.File]::ReadAllBytes($Target)
    $currentHash = Hash-Bytes $current
    $backup = $Target + '.pcl-offline-original.bak'
    $record = $Target + '.pcl-offline.txt'
    [byte[]]$source = $current
    if ([IO.File]::Exists($record)) {
        $lines = [IO.File]::ReadAllLines($record)
        if (($lines.Length -ne 3) -or (($lines[0] -ne 'pcl-offline-1') -and ($lines[0] -ne 'pcl-offline-2') -and ($lines[0] -ne 'pcl-offline-3'))) { throw '备份记录格式不匹配。' }
        if (($currentHash -ne $lines[1]) -and ($currentHash -ne $lines[2])) { throw '程序已更新或被其他工具修改。请将新原版放到新文件夹后再运行。' }
        if (![IO.File]::Exists($backup)) { throw '找不到原版备份。' }
        $source = [IO.File]::ReadAllBytes($backup)
        if ((Hash-Bytes $source) -ne $lines[1]) { throw '原版备份校验失败。' }
        if ($Mode -eq 'Restore') {
            if ($currentHash -ne $lines[1]) { Atomic-Write $Target $source }
            Write-Host '已恢复原版。'
            exit 0
        }
        if (($Mode -eq 'Apply') -and ($currentHash -eq $lines[2]) -and ($lines[0] -eq 'pcl-offline-3')) { Write-Host '已应用此离线补丁，无需重复修改。'; exit 0 }
    } else {
        if ($Mode -eq 'Restore') { throw '未找到本版的恢复记录。若此前使用 v6，请用 v6 的恢复脚本。' }
        $legacy = @('2227b249e7aeafbd73643961a33ae68050e5ac1e0830d526c346eadd2a7fab80','c78d07219cbe14524dd810136894177473f4d2d442ef77df14465f518d94a35d','ca2e7a63c18f29468c81f4864bf51debcb31bca005ac61e7820a4644ee662cc9','3fb4d356a9dec695ae219e4bd99157e249d5e222ed1c94acf4e67a17bd9c4c97','541c9f95adecc9d3be1c56af4c7b1997c39d1fc41333202a78216fb97e2368af')
        if ($legacy -contains $currentHash) {
            $oldBackup = $Target + '.download-original.bak'
            if (![IO.File]::Exists($oldBackup)) { throw '升级早期补丁需要原 .download-original.bak 备份。' }
            $source = [IO.File]::ReadAllBytes($oldBackup)
            if ((Hash-Bytes $source) -ne '5b64d6d540c376390470cea3ab99d47661e8bca81be2ba647ea83e7d2e9428fa') { throw '早期补丁的原版备份不匹配。' }
        } elseif ([IO.File]::Exists($Target + '.pcl-universal.json')) {
            $oldRecord = [IO.File]::ReadAllText($Target + '.pcl-universal.json')
            $originalMatch = [regex]::Match($oldRecord,'"original_sha256"\s*:\s*"([0-9a-f]{64})"')
            $patchedMatch = [regex]::Match($oldRecord,'"patched_sha256"\s*:\s*"([0-9a-f]{64})"')
            if (!$originalMatch.Success -or !$patchedMatch.Success) { throw 'Python 版备份记录无法识别。' }
            if (($currentHash -ne $originalMatch.Groups[1].Value) -and ($currentHash -ne $patchedMatch.Groups[1].Value)) { throw '文件与 Python 版备份记录不匹配，已停止。' }
            $source = [IO.File]::ReadAllBytes($Target + '.pcl-universal-original.bak')
            if ((Hash-Bytes $source) -ne $originalMatch.Groups[1].Value) { throw 'Python 版原始备份校验失败。' }
        }
    }
    $library = Join-Path $base 'lib\dnlib.dll'
    if ((Hash-Bytes ([IO.File]::ReadAllBytes($library))) -ne 'a4674bd69a0b1b6bb74343c55f1211686c5c1f801c313d8d5d7538f9ff94f87d') { throw 'dnlib 解析库校验失败，请重新解压完整脚本包。' }
    # PowerShell 2's compiler may not resolve short assembly filenames.
    $coreAssembly = [Reflection.Assembly]::LoadWithPartialName('System.Core')
    if (($null -eq $coreAssembly) -or [string]::IsNullOrEmpty($coreAssembly.Location)) {
        throw '系统 .NET 未能加载 System.Core；请确认 .NET Framework 3.5 组件正常。'
    }
    $corePath = $coreAssembly.Location
    if (![IO.File]::Exists($corePath)) {
        throw '系统程序集完整路径无效，未执行补丁。'
    }
    # PowerShell 2 may use the C# 2 compiler through Add-Type. Select the compiler explicitly.
    $providerOptions = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if ([Environment]::Version.Major -ge 4) { $providerOptions.Add('CompilerVersion','v4.0') }
    else { $providerOptions.Add('CompilerVersion','v3.5') }
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider -ArgumentList (,$providerOptions)
    try {
        $compiler = New-Object System.CodeDom.Compiler.CompilerParameters
        $compiler.GenerateExecutable = $false
        $compiler.GenerateInMemory = $true
        $compiler.IncludeDebugInformation = $false
        $compiler.ReferencedAssemblies.Add($corePath) | Out-Null
        $compiler.ReferencedAssemblies.Add($library) | Out-Null
        # CLR 4's HashSet implements ISet from System.dll. Its CodeDOM compiler
        # requires an explicit reference here; retain the working CLR 2 setup.
        if ([Environment]::Version.Major -ge 4) {
            $systemPath = [System.Uri].Assembly.Location
            if (![IO.File]::Exists($systemPath)) { throw '无法定位当前 .NET 4 的 System.dll。' }
            $compiler.ReferencedAssemblies.Add($systemPath) | Out-Null
        }
        # The exact core is embedded to prevent old external .cs files being compiled.
        $coreSource = @'
// Source for offline PowerShell Add-Type. Requires bundled dnlib net35 only.
using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using dnlib.DotNet;
using dnlib.DotNet.Emit;
using dnlib.DotNet.Writer;

// Install before touching types whose signatures refer to dnlib. CLR 2 does not
// reliably bind an in-memory CodeDOM assembly to a dependency in LoadFrom context.
public static class PclOfflineResolver {
 static System.Reflection.Assembly library;
 public static void Install(string path) {
  library=System.Reflection.Assembly.Load(File.ReadAllBytes(path));
  AppDomain.CurrentDomain.AssemblyResolve += Resolve;
 }
 static System.Reflection.Assembly Resolve(object sender,ResolveEventArgs args) {
  System.Reflection.AssemblyName requested=new System.Reflection.AssemblyName(args.Name);
  if(library!=null && requested.FullName==library.GetName().FullName)return library;
  return null;
 }
}

public sealed class PclPatchResult {
 public byte[] Data;
 public string Version;
 public string[] Changes;
}
public static class PclPatchCore {
 static void Need(bool ok,string msg) { if(!ok) throw new InvalidOperationException(msg); }
 static TypeDef Type(ModuleDef m,string name) {
  TypeDef[] a=m.GetTypes().Where(delegate(TypeDef t){return t.Name==name;}).ToArray();
  Need(a.Length==1,"类型不唯一或缺失："+name);return a[0];
 }
 static MethodDef Method(TypeDef t,string name,int count) {
  MethodDef[] a=t.Methods.Where(delegate(MethodDef x){return x.Name==name && x.MethodSig.Params.Count==count;}).ToArray();
  Need(a.Length==1,"方法不唯一或缺失："+t.Name+"."+name);Need(a[0].HasBody,"方法没有 IL："+name);return a[0];
 }
 static string Name(Instruction i) { IMethod x=i.Operand as IMethod;return x==null?"":x.Name.String; }
 static Instruction I(OpCode op,object value) { return new Instruction(op,value); }
 static Instruction I(OpCode op) { return new Instruction(op); }
 static bool Restriction(Instruction x) { return x.OpCode==OpCodes.Ldstr && ((string)x.Operand).Contains("不再提供 MC 下载功能"); }
 static int FindRestriction(MethodDef m) {
  int[] p=Enumerable.Range(0,m.Body.Instructions.Count).Where(delegate(int i){return Restriction(m.Body.Instructions[i]);}).ToArray();
  Need(p.Length<=1,"限制块不唯一："+m.FullName);return p.Length==0?-1:p[0];
 }
 static void Replace(MethodDef m,int first,int last,IList<Instruction> added) {
  IList<Instruction> xs=m.Body.Instructions;
  HashSet<Instruction> removed=new HashSet<Instruction>(xs.Skip(first).Take(last-first+1));
  Need(added.Count>0,"不能替换为空指令集");Instruction start=added[0];
  foreach(Instruction x in xs) {
   Instruction b=x.Operand as Instruction;if(b!=null && removed.Contains(b))x.Operand=start;
   IList<Instruction> bs=x.Operand as IList<Instruction>;
   if(bs!=null)for(int k=0;k<bs.Count;k++)if(removed.Contains(bs[k]))bs[k]=start;
  }
  foreach(ExceptionHandler e in m.Body.ExceptionHandlers) {
   if(e.TryStart!=null && removed.Contains(e.TryStart))e.TryStart=start;
   if(e.TryEnd!=null && removed.Contains(e.TryEnd))e.TryEnd=start;
   if(e.HandlerStart!=null && removed.Contains(e.HandlerStart))e.HandlerStart=start;
   if(e.HandlerEnd!=null && removed.Contains(e.HandlerEnd))e.HandlerEnd=start;
   if(e.FilterStart!=null && removed.Contains(e.FilterStart))e.FilterStart=start;
  }
  for(int k=last;k>=first;k--)xs.RemoveAt(k);
  for(int k=0;k<added.Count;k++)xs.Insert(first+k,added[k]);
 }
 static MethodDef DelegateCtor(ModuleDef mod,TypeSig sig) {
  TypeDef[] ts=mod.GetTypes().Where(delegate(TypeDef t){return t.FullName==sig.FullName;}).ToArray();
  Need(ts.Length==1,"无法定位内部委托："+sig.FullName);
  MethodDef[] cs=ts[0].Methods.Where(delegate(MethodDef x){return x.IsInstanceConstructor;}).ToArray();
  Need(cs.Length==1,"委托构造方法不唯一");return cs[0];
 }
 static FieldDef Field(TypeDef t,string name) {
  FieldDef[] fs=t.Fields.Where(delegate(FieldDef f){return f.Name==name;}).ToArray();
  Need(fs.Length==1,"字段不唯一或缺失："+name);return fs[0];
 }
 static void FixDownload(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  TypeDef t=Type(m,"PageDownloadInstall");MethodDef f=Method(t,"LoaderInit",0);
  IList<Instruction> xs=f.Body.Instructions;
  int[] starts=Enumerable.Range(0,xs.Count).Where(delegate(int i){return xs[i].OpCode==OpCodes.Ldstr && (string)xs[i].Operand=="关闭下载";}).ToArray();
  if(starts.Length==0)return;Need(starts.Length==1,"下载替代加载器不唯一");int start=starts[0],end=-1;
  for(int k=start+1;k<xs.Count;k++) {
   IMethod call=xs[k].Operand as IMethod;
   if(xs[k].OpCode==OpCodes.Newobj && call!=null && call.DeclaringType.TypeName=="LoaderTask`2") {end=k;break;}
  }
  Need(end>=0,"找不到替代加载器构造方法");
  FieldDef loader=Field(Type(m,"ModDownload"),"DlClientListLoader");
  Need(start>0 && xs[start-1].OpCode==OpCodes.Ldnull,"缺少必须保留的外层 Nothing 参数");
  Replace(f,start,end,new Instruction[]{I(OpCodes.Ldsfld,loader)});changed.Add(f);notes.Add("恢复原版下载列表入口");
 }
 static void FixDispatcher(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  TypeDef t=Type(m,"ModModpack");MethodDef f=Method(t,"ModpackInstall",3);int pos=FindRestriction(f);if(pos<0)return;
  IList<Instruction> xs=f.Body.Instructions;
  Need(pos+2<xs.Count && xs[pos+1].OpCode==OpCodes.Newobj && xs[pos+2].OpCode==OpCodes.Throw,"整合包限制块结构变化");
  bool existing=xs.Any(delegate(Instruction x){return x.OpCode==OpCodes.Call && Name(x)=="InstallPackCurseForge";});
  if(existing) Replace(f,pos,pos+2,new Instruction[]{I(OpCodes.Nop)});
  else {
   f.Body.SimplifyMacros(f.Parameters);xs=f.Body.Instructions;pos=FindRestriction(f);
   Local[] packs=Enumerable.Range(0,pos-1).Where(delegate(int k){return xs[k].IsLdcI4() && xs[k].GetLdcI4Value()==-1 && xs[k+1].OpCode==OpCodes.Stloc;}).Select(delegate(int k){return (Local)xs[k+1].Operand;}).Distinct().ToArray();
   Local[] archives=f.Body.Variables.Where(delegate(Local l){return l.Type.TypeName=="ZipArchive";}).ToArray();
   Local[] results=f.Body.Variables.Where(delegate(Local l){return l.Type.FullName==f.MethodSig.RetType.FullName;}).ToArray();
   Local[] bases=Enumerable.Range(0,pos-1).Where(delegate(int k){return xs[k].OpCode==OpCodes.Ldstr && (string)xs[k].Operand=="" && xs[k+1].OpCode==OpCodes.Stloc;}).Select(delegate(int k){return (Local)xs[k+1].Operand;}).Distinct().ToArray();
   Need(packs.Length==1 && archives.Length==1 && results.Length==1 && bases.Length==1,"整合包局部变量结构无法确定");
   ExceptionHandler outer=f.Body.ExceptionHandlers.OrderBy(delegate(ExceptionHandler e){return xs.IndexOf(e.TryStart);}).First();
   Need(outer.HandlerType==ExceptionHandlerType.Finally && outer.HandlerStart==xs[pos+3] && outer.HandlerEnd==null,"外层压缩包 finally 结构变化");
   Local pack=packs[0],archive=archives[0],result=results[0],baseFolder=bases[0];
   List<Instruction> add=new List<Instruction>();Instruction epilog=I(OpCodes.Ldloc,result);
   int[] values={0,1,2,3,4,9};string[] names={"InstallPackCurseForge","InstallPackHMCL","InstallPackMMC","InstallPackMCBBS","InstallPackModrinth","InstallPackLauncherPack","InstallPackCompress"};int[] nargs={5,3,3,4,5,3,2};
   Instruction[] labels=Enumerable.Range(0,7).Select(delegate(int k){return I(OpCodes.Nop);}).ToArray();
   for(int k=0;k<values.Length;k++){add.Add(I(OpCodes.Ldloc,pack));add.Add(Instruction.CreateLdcI4(values[k]));add.Add(I(OpCodes.Beq,labels[k]));}
   add.Add(I(OpCodes.Br,labels[6]));
   for(int k=0;k<7;k++) {
    MethodDef call=Method(t,names[k],nargs[k]);Need(call.MethodSig.RetType.FullName==result.Type.FullName,"安装器返回类型不匹配");
    add.Add(labels[k]);add.Add(I(OpCodes.Ldarg,f.Parameters[0]));add.Add(I(OpCodes.Ldloc,archive));
    if(nargs[k]>=3)add.Add(I(OpCodes.Ldloc,baseFolder));if(nargs[k]>=4)add.Add(I(OpCodes.Ldarg,f.Parameters[1]));if(nargs[k]>=5)add.Add(I(OpCodes.Ldarg,f.Parameters[2]));
    add.Add(I(OpCodes.Call,call));add.Add(I(OpCodes.Stloc,result));add.Add(I(OpCodes.Leave,epilog));
   }
   Replace(f,pos,pos+2,add);
   // Keep the original finally end outside the new return epilogue.
   outer.HandlerEnd=epilog;xs.Add(epilog);xs.Add(I(OpCodes.Ret));
  }
  changed.Add(f);notes.Add("恢复整合包格式分发和 finally 清理");
 }
 static void FixManual(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  TypeDef pack=Type(m,"ModModpack");MethodDef f=Method(pack,"ModpackInstall",0);if(FindRestriction(f)<0)return;
  IMethod[] ctors=f.Body.Instructions.Where(delegate(Instruction x){return x.OpCode==OpCodes.Newobj;}).Select(delegate(Instruction x){return (IMethod)x.Operand;}).Where(delegate(IMethod c){return c is MethodDef;}).ToArray();
  Need(ctors.Length==1,"手动导入闭包构造方法不唯一");MethodDef ctor=(MethodDef)ctors[0];TypeDef closure=ctor.DeclaringType;
  FieldDef[] files=closure.Fields.Where(delegate(FieldDef x){return x.Name.String.EndsWith("Local_File");}).ToArray();
  MethodDef target=Method(pack,"ModpackInstall",3);
  MethodDef[] funcs=closure.Methods.Where(delegate(MethodDef x){return x.HasBody && x.Body.Instructions.Any(delegate(Instruction y){return y.OpCode==OpCodes.Call && y.Operand==target;});}).ToArray();
  Need(files.Length==1 && funcs.Length==1 && f.Body.Variables.Count==1,"手动导入闭包结构不匹配");
  MethodDef[] samples=m.GetTypes().SelectMany(delegate(TypeDef x){return x.Methods;}).Where(delegate(MethodDef x){return x.Name=="McSkinSelect" && x.HasBody;}).ToArray();Need(samples.Length==1,"缺少可复用的文件选择器");
  IList<Instruction> sample=samples[0].Body.Instructions;int si=-1;
  for(int k=0;k<sample.Count;k++)if(Name(sample[k])=="SelectFile") {Need(si<0,"文件选择器调用不唯一");si=k;}
  Need(si>0 && si+1<sample.Count && Name(sample[si+1])=="FirstOrDefault" && sample[0].OpCode==OpCodes.Ldstr,"文件选择器调用结构变化");
  int lastString=-1;for(int k=0;k<si;k++)if(sample[k].OpCode==OpCodes.Ldstr)lastString=k;
  MemberRef[] action=m.GetMemberRefs().Where(delegate(MemberRef c){return c.Name==".ctor" && c.DeclaringType.FullName=="System.Action" && c.MethodSig.Params.Count==2;}).ToArray();Need(action.Length==1,"Action 构造方法不唯一");
  MethodDef[] runs=m.GetTypes().SelectMany(delegate(TypeDef x){return x.Methods;}).Where(delegate(MethodDef x){return x.Name=="RunInThread" && x.IsStatic && x.MethodSig.Params.Count==1 && x.MethodSig.Params[0].FullName=="System.Action";}).ToArray();Need(runs.Length==1,"后台线程方法不唯一");
  MemberRef[] empties=m.GetMemberRefs().Where(delegate(MemberRef x){return x.Name=="IsNullOrEmpty" && x.DeclaringType.FullName=="System.String";}).ToArray();Need(empties.Length==1,"字符串校验方法不唯一");
  CilBody body=new CilBody();body.InitLocals=true;Local local=new Local(f.Body.Variables[0].Type);body.Variables.Add(local);
  IList<Instruction> ins=body.Instructions;ins.Add(I(OpCodes.Newobj,ctor));ins.Add(I(OpCodes.Stloc,local));ins.Add(I(OpCodes.Ldloc,local));int filter=0;
  for(int k=0;k<=si+1;k++) {
   Instruction x=sample[k];Need(x.OpCode.FlowControl!=FlowControl.Branch && x.OpCode.FlowControl!=FlowControl.Cond_Branch,"文件选择参数包含分支");
   if(x.OpCode==OpCodes.Ldstr) {
    string s=(string)x.Operand;if(k==0 || k==lastString)s="选择整合包压缩文件";
    else {Need(new string[]{"png","jpg","jpeg","webp","bmp","gif"}.Contains(s.ToLowerInvariant()),"未知的筛选项："+s);s=new string[]{"zip","mrpack","rar"}[filter++%3];}
    ins.Add(I(OpCodes.Ldstr,s));
   } else ins.Add(I(x.OpCode,x.Operand));
  }
  Need(filter>=2,"筛选项结构异常");
  ins.Add(I(OpCodes.Stfld,files[0]));Instruction end=I(OpCodes.Ret);
  ins.Add(I(OpCodes.Ldloc,local));ins.Add(I(OpCodes.Ldfld,files[0]));ins.Add(I(OpCodes.Call,empties[0]));ins.Add(I(OpCodes.Brtrue,end));
  ins.Add(I(OpCodes.Ldloc,local));ins.Add(I(OpCodes.Ldftn,funcs[0]));ins.Add(I(OpCodes.Newobj,action[0]));ins.Add(I(OpCodes.Call,runs[0]));ins.Add(end);
  f.Body=body;changed.Add(f);notes.Add("恢复手动选择整合包入口");
 }
 static void FixOnline(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  TypeDef type=Type(m,"PageDownloadResourceDetail");MethodDef f=Method(type,"InitializeStackResourceVersions",1),install=Method(type,"Install_Click",2),save=Method(type,"Save_Click",2);
  IList<Instruction> xs=f.Body.Instructions;if(xs.Any(delegate(Instruction x){return x.OpCode==OpCodes.Ldftn && x.Operand==install;}))return;
  int[] hits=Enumerable.Range(0,xs.Count).Where(delegate(int i){return xs[i].OpCode==OpCodes.Ldftn && xs[i].Operand==save;}).ToArray();Need(hits.Length==1,"另存为回调不唯一");int j=hits[0];
  Need(j>=1 && j+4<xs.Count && xs[j-1].OpCode==OpCodes.Ldarg_0 && xs[j+1].OpCode==OpCodes.Newobj && xs[j+2].OpCode==OpCodes.Ldnull && Name(xs[j+4])=="ToListItem","版本行调用结构变化");
  IMethod call=(IMethod)xs[j+4].Operand;Need(call.MethodSig.Params.Count==3,"版本行参数个数不匹配");
  MethodDef rowCtor=DelegateCtor(m,call.MethodSig.Params[0]),buttonCtor=DelegateCtor(m,call.MethodSig.Params[1]);Need(rowCtor!=buttonCtor,"委托类型应当不同");
  FieldDef field=Field(type,"TargetResourceType");List<int> values=new List<int>();
  for(int k=0;k<xs.Count-2;k++)if(xs[k].OpCode==OpCodes.Ldfld && xs[k].Operand==field && xs[k+1].IsLdcI4() && (xs[k+2].OpCode==OpCodes.Bne_Un_S || xs[k+2].OpCode==OpCodes.Bne_Un)) values.Add(xs[k+1].GetLdcI4Value());
  Need(values.Distinct().Count()==1,"无法确定 ModPack 类型判定值");
  Instruction normal=I(OpCodes.Ldarg_0),done=I(OpCodes.Nop);List<Instruction> add=new List<Instruction>();
  add.Add(I(OpCodes.Ldarg_0));add.Add(I(OpCodes.Ldfld,field));add.Add(Instruction.CreateLdcI4(values[0]));add.Add(I(OpCodes.Bne_Un,normal));
  add.Add(I(OpCodes.Ldarg_0));add.Add(I(OpCodes.Ldftn,install));add.Add(I(OpCodes.Newobj,rowCtor));
  add.Add(I(OpCodes.Ldarg_0));add.Add(I(OpCodes.Ldftn,save));add.Add(I(OpCodes.Newobj,buttonCtor));add.Add(I(OpCodes.Br,done));
  add.Add(normal);add.Add(I(OpCodes.Ldftn,save));add.Add(I(OpCodes.Newobj,rowCtor));add.Add(I(OpCodes.Ldnull));add.Add(done);
  Replace(f,j-1,j+2,add);changed.Add(f);notes.Add("恢复在线整合包安装与独立另存为按钮");
 }
 static void FixHiddenUI(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  TypeDef left=Type(m,"PageDownloadLeft");MethodDef ctor=Method(left,".ctor",0);
  IList<Instruction> xs=ctor.Body.Instructions;
  int init=-1;for(int k=0;k<xs.Count;k++)if(Name(xs[k])=="InitializeComponent")init=k;
  Need(init>=0,"下载侧栏缺少初始化方法");
  if(xs.Skip(init+1).Any(delegate(Instruction x){return Name(x)=="get_ItemInstall";})) {
   // Accept only the known constructor tail: hide two controls and switch to Mod.
   IList<Instruction> tail=xs.Skip(init+1).ToArray();
   Need(tail.Count==16 && tail[0].OpCode==OpCodes.Ldarg_0 && Name(tail[1])=="get_ItemInstall" && tail[2].IsLdcI4() && tail[2].GetLdcI4Value()==2 && Name(tail[3])=="set_Visibility" && tail[4].OpCode==OpCodes.Ldarg_0 && Name(tail[5])=="get_LabResource" && tail[6].IsLdcI4() && tail[6].GetLdcI4Value()==2 && Name(tail[7])=="set_Visibility" && tail[8].OpCode==OpCodes.Ldarg_0 && tail[9].IsLdcI4() && tail[10].OpCode==OpCodes.Stfld && ((IField)tail[10].Operand).Name=="PageID" && tail[11].OpCode==OpCodes.Ldarg_0 && Name(tail[12])=="get_ItemMod" && tail[13].IsLdcI4() && tail[13].GetLdcI4Value()==1 && Name(tail[14])=="set_Checked" && tail[15].OpCode==OpCodes.Ret,"下载侧栏隐藏代码结构变化，已停止");
   Need(xs.Take(init).Any(delegate(Instruction x){return x.OpCode==OpCodes.Stfld && ((IField)x.Operand).Name=="PageID";}),"下载侧栏缺少默认页面初始化");
   Replace(ctor,init+1,xs.Count-2,new Instruction[]{I(OpCodes.Nop)});
   changed.Add(ctor);notes.Add("恢复下载侧栏的原版游戏入口与默认页面");
  }
  TypeDef resource=Type(m,"PageResource");MethodDef setter=Method(resource,"set_PageType",1);
  xs=setter.Body.Instructions;
  int p=-1;for(int k=0;k<xs.Count-4;k++)if(xs[k].OpCode==OpCodes.Ldarg_1 && xs[k+1].IsLdcI4() && xs[k+2].OpCode==OpCodes.Pop && xs[k+3].OpCode==OpCodes.Pop && xs[k+4].IsLdcI4() && xs[k+4].GetLdcI4Value()==2) {Need(p<0,"导入按钮限制块不唯一");p=k;}
  if(p>=0) {
   Need(p>0 && p+5<xs.Count && Name(xs[p+5])=="set_Visibility","导入按钮可见性调用变化");
   IMethod getter=xs.Select(delegate(Instruction x){return x.Operand as IMethod;}).FirstOrDefault(delegate(IMethod x){return x!=null && x.Name=="get_BtnSearchInstallModPack";});
   Need(getter!=null,"找不到导入按钮控件");int packType=xs[p+1].GetLdcI4Value();
   // Replace only the value expression; preserve setter's equality check and backing field assignment.
   Instruction collapsed=Instruction.CreateLdcI4(2),apply=I(OpCodes.Nop);
   List<Instruction> add=new List<Instruction>();
   add.Add(I(OpCodes.Ldarg_1));add.Add(Instruction.CreateLdcI4(packType));add.Add(I(OpCodes.Bne_Un,collapsed));
   add.Add(Instruction.CreateLdcI4(0));add.Add(I(OpCodes.Br,apply));add.Add(collapsed);add.Add(apply);
   Replace(setter,p,p+4,add);changed.Add(setter);notes.Add("恢复整合包页面的导入按钮（其他资源页面不显示）");
  }
 }

 static void FixVersionSelectImport(ModuleDef m,List<string> notes,List<MethodDef> changed) {
  MethodDef f=Method(Type(m,"PageSelectLeft"),"McFolderListUI",0);
  f.Body.SimplifyMacros(f.Parameters);IList<Instruction> xs=f.Body.Instructions;
  int[] titles=Enumerable.Range(0,xs.Count).Where(delegate(int k){return xs[k].OpCode==OpCodes.Ldstr && (string)xs[k].Operand=="导入整合包";}).ToArray();
  Need(titles.Length==1,"版本选择页的导入列表项不唯一");int title=titles[0],store=-1;
  for(int k=title+1;k<xs.Count;k++)if(xs[k].OpCode==OpCodes.Stloc) {store=k;break;}
  Need(store>=0,"版本选择导入列表项缺少局部变量");Local item=(Local)xs[store].Operand;
  // If the item is already inserted into Children, leave that version untouched.
  for(int k=0;k<xs.Count-1;k++)if(xs[k].OpCode==OpCodes.Ldloc && xs[k].Operand==item && Name(xs[k+1])=="Add")return;
  int template=-1;
  for(int k=0;k<title-5;k++) {
   if(xs[k].OpCode==OpCodes.Ldsfld && Name(xs[k+1])=="get_PanList" && Name(xs[k+2])=="get_Children" && xs[k+3].OpCode==OpCodes.Ldloc && Name(xs[k+4])=="Add" && xs[k+5].OpCode==OpCodes.Pop)template=k;
  }
  Need(template>=0,"无法确定版本选择列表的添加方法");
  int hook=-1;
  for(int k=store+1;k<xs.Count;k++)if(Name(xs[k])=="add_Click") {hook=k;break;}
  Need(hook>store,"版本选择导入列表项缺少点击绑定");
  IMethod target=null;
  for(int k=store+1;k<hook;k++)if(xs[k].OpCode==OpCodes.Ldftn)target=(IMethod)xs[k].Operand;
  Need(target!=null,"无法识别版本选择导入按钮的事件回调");
  MethodDef callback=target as MethodDef;Need(callback!=null && callback.HasBody,"导入按钮回调无方法体");
  // Validate the delegate adapter eventually invokes the zero-argument import entry.
  MethodDef import=Method(Type(m,"ModModpack"),"ModpackInstall",0);
  bool links=callback.Body.Instructions.Any(delegate(Instruction x){return x.Operand==import;});
  if(!links) {
   foreach(Instruction call in callback.Body.Instructions) {
    MethodDef inner=call.Operand as MethodDef;
    if(inner!=null && inner.HasBody && inner.Body.Instructions.Any(delegate(Instruction x){return x.Operand==import;}))links=true;
   }
  }
  Need(links,"导入按钮的回调未连接到安装入口，已停止");
  List<Instruction> add=new List<Instruction>();
  for(int k=0;k<6;k++)add.Add(k==3?I(OpCodes.Ldloc,item):I(xs[template+k].OpCode,xs[template+k].Operand));
  add.Add(xs[store+1]);Replace(f,store+1,store+1,add);
  changed.Add(f);notes.Add("恢复版本选择页“添加或导入”区域的导入整合包按钮");
 }

 public static PclPatchResult Patch(byte[] input) {
  using(ModuleDefMD m=ModuleDefMD.Load(input, (ModuleCreationOptions)null)) {
   Need(m.IsILOnly,"暂不支持混合模式程序");Need(!m.IsStrongNameSigned,"暂不支持强名称签名程序");Need(m.Assembly!=null,"不是有效程序集");
   List<string> notes=new List<string>();List<MethodDef> changed=new List<MethodDef>();
   FixVersionSelectImport(m,notes,changed);FixHiddenUI(m,notes,changed);FixDownload(m,notes,changed);FixDispatcher(m,notes,changed);FixManual(m,notes,changed);FixOnline(m,notes,changed);
   Need(changed.Count>0,"没有找到待修复入口；此版本可能不需要补丁或结构尚未适配");
   foreach(MethodDef method in changed) {
    method.Body.SimplifyBranches();method.Body.OptimizeBranches();method.Body.KeepOldMaxStack=false;
    uint stack;Need(MaxStackCalculator.GetMaxStack(method.Body.Instructions,method.Body.ExceptionHandlers,out stack),"求值栈校验失败："+method.FullName);
    method.Body.MaxStack=(ushort)stack;
   }
   using(MemoryStream output=new MemoryStream()) {
    ModuleWriterOptions options=new ModuleWriterOptions(m);options.MetadataOptions.Flags|=MetadataFlags.PreserveAll;
    m.Write(output,options);byte[] result=output.ToArray();
    using(ModuleDefMD verify=ModuleDefMD.Load(result, (ModuleCreationOptions)null)) {
     foreach(MethodDef old in changed) {
      MethodDef found=Method(Type(verify,old.DeclaringType.Name),old.Name,old.MethodSig.Params.Count);uint stack;
      Need(MaxStackCalculator.GetMaxStack(found.Body.Instructions,found.Body.ExceptionHandlers,out stack),"写入后栈校验失败："+old.FullName);
     }
    }
    return new PclPatchResult {Data=result,Version=m.Assembly.Version.ToString(),Changes=notes.ToArray()};
   }
  }
 }
}

'@
        $compiled = $provider.CompileAssemblyFromSource($compiler,[string[]]@($coreSource))
        if ($compiled.Errors.HasErrors) {
            $messages = @()
            foreach ($errorItem in $compiled.Errors) {
                if (!$errorItem.IsWarning) { $messages += $errorItem.ToString() }
            }
            throw ([string]::Join("`r`n",[string[]]$messages))
        }
        $compiledAssembly = $compiled.CompiledAssembly
        # Direct static calls use PowerShell's argument binder, which unwraps PSObject.
        [PclOfflineResolver]::Install([string]$library)
    } finally {
        # IDisposable is explicit on some old framework types.
        if ($provider -is [IDisposable]) { ([IDisposable]$provider).Dispose() }
    }
    $result = [PclPatchCore]::Patch([byte[]]$source)
    Write-Host ('识别到程序集版本：' + $result.Version)
    foreach ($change in $result.Changes) { Write-Host ('  ' + $change) }
    if ($Mode -eq 'Check') { Write-Host '结构、方法求值栈及写入后解析通过，未修改文件。'; exit 0 }
    if ((Hash-Bytes ([IO.File]::ReadAllBytes($Target))) -ne $currentHash) { throw '程序在操作期间发生变化，已停止。' }
    if ([IO.File]::Exists($backup)) {
        if ((Hash-Bytes ([IO.File]::ReadAllBytes($backup))) -ne (Hash-Bytes $source)) { throw '已有原版备份不匹配，拒绝覆盖。' }
    } else { [IO.File]::WriteAllBytes($backup,$source) }
    $text = 'pcl-offline-3' + "`r`n" + (Hash-Bytes $source) + "`r`n" + (Hash-Bytes $result.Data) + "`r`n"
    Atomic-Write $record ([Text.Encoding]::UTF8.GetBytes($text))
    Atomic-Write $Target $result.Data
    Write-Host '离线通用补丁已应用，请重新打开 PCL 测试。'
    exit 0
} catch {
    $err = $_.Exception
    while ($err.InnerException) { $err = $err.InnerException }
    Write-Host ('失败：' + $err.Message) -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host $_.InvocationInfo.PositionMessage }
    Write-Host '结构不匹配时不会修改程序；请先退出 PCL，并保留全部备份文件。'
    exit 1
}
