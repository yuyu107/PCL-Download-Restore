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
 static bool Restriction(Instruction x) { return x.OpCode==OpCodes.Ldstr && ((string)x.Operand).Contains("暂时不再提供 MC 下载功能"); }
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
 public static PclPatchResult Patch(byte[] input) {
  using(ModuleDefMD m=ModuleDefMD.Load(input, (ModuleCreationOptions)null)) {
   Need(m.IsILOnly,"暂不支持混合模式程序");Need(!m.IsStrongNameSigned,"暂不支持强名称签名程序");Need(m.Assembly!=null,"不是有效程序集");
   List<string> notes=new List<string>();List<MethodDef> changed=new List<MethodDef>();
   FixDownload(m,notes,changed);FixDispatcher(m,notes,changed);FixManual(m,notes,changed);FixOnline(m,notes,changed);
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
