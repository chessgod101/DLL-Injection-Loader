program Loader;
uses
  Windows;

CONST
MainEXE:WideString='YOUREXENAMEHERE.exe';//name of exe(no preceding slash)
InjectDLL:WideString='YOURDLLNAMEHERE.dll';//name of dll(no preceding slash)

type PROCESS_BASIC_INFORMATION = Record
	ExitStatus:Pointer;
	PebBaseAddress:Pointer;
	AffinityMask:Pointer;
	BasePriority:Pointer;
	UniqueProcessId:Pointer;
	InheritedFromUniqueProcessId:Pointer;
End;

CONST INVALID_FILE_ATTRIBUTES=$FFFFFFFF;

Function NtQueryInformationProcess(handle:THandle; ProcessInformationClass:Cardinal; ProcessInformation:Pointer; ProcessInformationLength:Cardinal;var ReturnLength:Cardinal):Cardinal; STDCALL; External 'ntdll.dll';

Function GetCurDir():WideString;
var
	me:Array[0..1023] of wideChar;
Begin
	GetCurrentDirectoryW(1024,@me[0]);
	Result:=WideString(me);
End;

Function FileExists(fname:WideString):Boolean;
var
d:Cardinal;
Begin
	d:=GetFileAttributesW(@fname[1]);
	if (d=INVALID_FILE_ATTRIBUTES) or (d=FILE_ATTRIBUTE_DIRECTORY) then
		result:=false
	else
		Result:=true;
End;

Function InjectDllW(hprocess: tHandle;  DLLPath: WideString):Boolean;
var
  TID: thandle;
  Parameters: pointer;
  BytesWritten:cardinal;
  pThreadStartRoutine: Pointer;
begin
  Parameters := VirtualAllocEx( hProcess, nil, Length(DLLPath)*2+1, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  WriteProcessMemory(hProcess,Parameters,Pointer(DLLPath),Length(DLLPath)*2+1,BytesWritten);
  pThreadStartRoutine := GetProcAddress(GetModuleHandle('KERNEL32.DLL'), 'LoadLibraryW');
  CreateRemoteThread(hProcess,  nil,  0,  pThreadStartRoutine,  Parameters,  0,  TID);
  Result:=true;
  CloseHandle(hProcess);
end;

Function GetEntryPoint(fname:WideString):Cardinal;
var
	fh:THandle;
	dh:tImageDosHeader;
	oh:TImageOptionalHeader;
	tmp:Cardinal;
Begin
	fh:=CreateFileW(@fname[1],GENERIC_READ,FILE_SHARE_READ,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
	if fh=INVALID_HANDLE_VALUE then begin
		Result:=0;
		exit;
	end;
	if ReadFile(fh,dh,sizeof(tImageDosHeader),tmp,nil)=false then begin
		CloseHandle(fh);
		Result:=0;
		exit;
	end;
	if dh.e_magic<>23117 then begin
		CloseHandle(fh);
		Result:=0;
		exit;
	end;
	SetFilePointer(fh,dh._lfanew+4+SizeOf(timageFileHeader),nil,FILE_BEGIN);
	if ReadFile(fh,oh,sizeof(TImageOptionalHeader),tmp,nil)=false then begin
		CloseHandle(fh);
		Result:=0;
	exit;
	end;
	CloseHandle(fh);
	Result:=oh.AddressOfEntryPoint;
	End;

Function GetModBase(hProcess:THandle):Cardinal;
var
	imgbase,tmp:cardinal;
	pbi:PROCESS_BASIC_INFORMATION;
begin
	result:=0;
	if NtQueryInformationProcess(hProcess,0,@pbi,sizeof(PROCESS_BASIC_INFORMATION),tmp)= 0 then begin
		if ReadProcessMemory(hProcess,pointer(cardinal(pbi.PebBaseAddress)+8),@imgBase,4,tmp)=true then
			result:=imgbase;
	end;
End;

Function DebugToBeginning(hProcess:THandle;hthread:THandle; ep:Cardinal):Boolean;
var
	epVA,tmp:Cardinal;
	CTX:TContext;
	storeBytes:Word;
CONST
	jmpV:Array[0..1] of byte=($eb,$fe);
Begin
	if ep=0 then begin
		result:=false;
		MessageBoxW(0,'Failed to get ep!','DebugToBeginning',0);
		exit;
	end;
	
	epVA:= GetModBase(hProcess)+ep;
	if ReadProcessMemory(hProcess,Pointer(epVA),@storeBytes,2,tmp)=false then begin
		result:=false;
		MessageBoxW(0,'Failed read ep!','DebugToBeginning',0);
		exit;
	end;
	
	if WriteProcessMemory(hProcess,Pointer(epVA),@jmpV[0],2,tmp)=false then begin
		result:=false;
		MessageBoxW(0,'Failed write ep!','DebugToBeginning',0);
		exit;
	end;
	
	ResumeThread(hThread);
	ZeroMemory(@CTX,SizeOF(TContext));
	CTX.ContextFlags:=CONTEXT_CONTROL;
	Sleep(500);
	Repeat
	if GetThreadContext(hthread,ctx)=false then begin
		result:=false;
		MessageBoxW(0,'Get Thread Context Failed!','DebugToBeginning',0);
		exit;
	end;
	Until (CTX.Eip=epVA);
	
	SuspendThread(hthread);
	if WriteProcessMemory(hProcess,Pointer(epVA),@storeBytes,2,tmp)=false then begin
		result:=false;
		MessageBoxW(0,'Failed to rewrite original bytes@','DebugToBeginning',0);
		exit;
	end;
	result:=true;
End;

Function GetParams():WideString;
var
	sLen,pLen:Cardinal;
	strV:PWideChar;
	sVal:WideChar;
Begin
	Result:='';
	strV:=GetCommandLineW();
	sLen:=0;

	while strV[sLen]<>#0 do inc(sLen);
	
	inc(sLen);

	if strV[0]='"' then begin
		sVal:='"';
		pLen:=1;
	end
	else begin
		sVal:=' ';
		pLen:=0;
	end;

	while strV[pLen]<>sVal do begin
		inc(pLen);
		if pLen>=sLen then Exit;
	end;

	inc(pLen);

	if sVal='"' then inc(pLen);

	setLength(result,sLen-pLen);
	CopyMemory(@result[1],@strV[pLen],(sLen-pLen)*2);
End;

Procedure MainRoutine();
var
  cdir,ldll,lexe,params:WideString;

  procInfo: PROCESS_INFORMATION;
  startupInformation:STARTUPINFO;
Begin
  cdir:=GetCurDir+'\';

  lexe:=cdir+MainEXE;
  if FileExists(lexe)=false then begin
   MessageBoxW(0,'EXE does not exist in this directory!','Error',MB_OK);
   exit;
  end;

  ldll:=cdir+InjectDLL;
  if FileExists(ldll)=false then begin
   MessageBoxW(0,'DLL does not exist in this directory!','Error',MB_OK);
   exit;
  end;

    params:='"'+lexe+'" '+GetParams;

  ZeroMemory(@startupInformation,sizeof(startupInformation));
  startupInformation.cb:=sizeof(startupInformation);

  if CreateProcessW(@lexe[1],@params[1],nil,nil,false,CREATE_SUSPENDED,
   nil,nil,startupInformation,procInfo)= false then begin
    MessageBoxW(0,'Failed to Create Process!','Error',MB_OK);
    exit;
   End;

  if DebugToBeginning(procInfo.hProcess,procInfo.hThread,GetEntryPoint(lexe))=false then begin
	TerminateProcess(procInfo.hProcess,0);
	CloseHandle(procInfo.hProcess);
	CloseHandle(procInfo.hThread);
	exit;
  end;

  if InjectDllW(procInfo.hProcess,ldll)=false then begin
   TerminateProcess(procInfo.hProcess,0);
   CloseHandle(procInfo.hProcess);
   CloseHandle(procInfo.hThread);
   exit;
  end;

  ResumeThread(procInfo.hThread);
  CloseHandle(procInfo.hProcess);
  CloseHandle(procInfo.hThread);
End;

begin
	MainRoutine;
end.
