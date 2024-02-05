unit Parted.Operations;

{$I configs.inc}

interface

uses
  Classes, SysUtils,
  Generics.Collections,
  FreeVision,
  UI.Commons,
  Parted.Logs,
  Parted.Commons,
  Parted.Partitions,
  Parted.Devices;

type
  TPartedOpKind = (
    okNothing = 0,
    okCreate,
    okDelete,
    okLabel,
    okFormat,
    okResize,
    okFlag
  );

  // The record used by okCreate operation
  PPartedOpDataCreate = ^TPartedOpDataCreate;
  TPartedOpDataCreate = packed record
    Flags: LongWord;
    FileSystem: LongWord;
    Preceding,
    Size: Int64;
    LabelName: UnicodeString;
    Name: UnicodeString;
    AffectedPart: PPartedPartition;
  end;

  // The record used by okResize operation
  PPartedOpDataResize = ^TPartedOpDataResize;
  TPartedOpDataResize = packed record
    Preceding,
    Size: Int64;
    AffectedPart: TPartedPartition;
  end;

  // The record used by okFlag operation
  PPartedOpDataFlags = ^TPartedOpDataFlags;
  TPartedOpDataFlags = packed record
    Flags: LongWord;
    AffectedPart: TPartedPartition;
  end;

  // The record used by okFormat operation
  PPartedOpDataFormat = ^TPartedOpDataFormat;
  TPartedOpDataFormat = packed record
    FileSystem: LongWord;
    AffectedPart: TPartedPartition;
  end;

  // The record used by okLabel operation
  PPartedOpDataLabel = ^TPartedOpDataLabel;
  TPartedOpDataLabel = packed record
    LabelName: UnicodeString;
    Name: UnicodeString;
    AffectedPart: TPartedPartition;
  end;

  PPartedOpDataDelete = ^TPartedOpDataDelete;
  TPartedOpDataDelete = packed record
    AffectedPart: TPartedPartition;
  end;

  PPartedOp = ^TPartedOp;
  TPartedOp = record
    Kind: TPartedOpKind;
    OpData: Pointer;
    Device: PPartedDevice;
    AffectedPartOld,
    AffectedPartNew: PPartedPartition;
  end;

  TPartedOpList = class(specialize TList<TPartedOp>)
  public
    destructor Destroy; override;
    procedure Remove(const AIndex: LongInt); // Remove op at index position
    procedure AddOp(const AKind: TPartedOpKind; const AData: Pointer; const AffectedPartOld: PPartedPartition); // Add a new op to the end of linked list
    function GetCurrentDevice: PPartedDevice;
    function Ptr(const AIndex: LongInt): PPartedOp;
    function GetLast: PPartedOp; // Get last op mode
    function GetOpCount: LongInt;
    procedure Undo; // Remove the last non-zero index op
    procedure Empty; // Remove all ops except the zero index op
    procedure Execute; // Execute op
  end;

implementation

uses
  FileSystem,
  FileSystem.Ext,
  FileSystem.NTFS,
  FileSystem.BTRFS,
  FileSystem.Swap,
  FileSystem.Fat;

destructor TPartedOpList.Destroy;
var
  I: LongInt;
begin
  for I := Pred(Self.Count) downto 0 do
  begin
    Self.Remove(I);
  end;
  inherited;
end;

function TPartedOpList.GetCurrentDevice: PPartedDevice;
begin
  Result := Self.GetLast^.Device;
end;

procedure TPartedOpList.Remove(const AIndex: LongInt);
var
  Op: TPartedOp;
begin
  if AIndex <= Pred(Self.Count) then
  begin
    Op := Self.Items[AIndex];
    Op.Device^.Done;
    if Op.OpData <> nil then
      FreeMem(Op.OpData);
    Dispose(Op.Device);
    Self.Delete(AIndex);
  end;
end;

function TPartedOpList.Ptr(const AIndex: LongInt): PPartedOp;
begin
  Result := @Self.FItems[AIndex];
end;

function TPartedOpList.GetLast: PPartedOp;
begin
  Result := @Self.FItems[Pred(Self.Count)];
end;

procedure TPartedOpList.AddOp(const AKind: TPartedOpKind; const AData: Pointer; const AffectedPartOld: PPartedPartition);
var
  LastOp,
  NewOp: TPartedOp;
  AffectedPartNew: PPartedPartition = nil; // Affected partition in NewOp's device
  I: LongInt;

  procedure FindNewlyAffectedPartition;
  var
    I: LongInt;
  begin
    for I := 0 to NewOp.Device^.GetPartitionCount - 1 do
    begin
      if NewOp.Device^.GetPartitionAt(I)^.OpID = AffectedPartOld^.OpID then
      begin
        AffectedPartNew := NewOp.Device^.GetPartitionAt(I);
        break;
      end;
    end;
    Assert(AffectedPartNew <> nil, 'AffectedPartNew = nil');
  end;

  procedure HandleCreate;
  var
    PData: PPartedOpDataCreate;
  begin
    PData := AData;
    // Split the part
    AffectedPartNew^.SplitPartitionInMB(PData^.Preceding, PData^.Size);
    AffectedPartNew^.Flags := FlagToSA(PData^.Flags, FlagArray);
    AffectedPartNew^.FileSystem := FileSystemFormattableArray[PData^.FileSystem];
    AffectedPartNew^.Name := PData^.Name;
    AffectedPartNew^.LabelName := PData^.LabelName;
    AffectedPartNew^.Kind := 'primary';
    AffectedPartNew^.AutoAssignNumber;
    AffectedPartNew^.Number := -AffectedPartNew^.Number;
  end;

  procedure HandleDelete;
  var
    PData: PPartedOpDataDelete;
  begin
    PData := AData;
    AffectedPartNew^.Number := 0;
    AffectedPartNew^.FileSystem := '';
    AffectedPartNew^.Name := '';
    AffectedPartNew^.LabelName := '';
    SetLength(AffectedPartNew^.Flags, 0);
    AffectedPartNew^.Device^.MergeUnallocatedSpace;
  end;

  procedure HandleFlag;
  var
    PData: PPartedOpDataFlags;
  begin
    PData := AData;
    AffectedPartNew^.Flags := FlagToSA(PData^.Flags, FlagArray);
  end;

  procedure HandleLabel;
  var
    PData: PPartedOpDataLabel;
  begin
    PData := AData;
    AffectedPartNew^.LabelName := PData^.LabelName;
    AffectedPartNew^.Name := PData^.Name;
  end;

  procedure HandleFormat;
  var
    PData: PPartedOpDataFormat;
  begin
    PData := AData;
    AffectedPartNew^.FileSystem := FileSystemFormattableArray[PData^.FileSystem];
  end;

  procedure HandleResize;
  var
    PData: PPartedOpDataResize;
  begin
    PData := AData;
    AffectedPartNew^.ResizePartitionInMB(PData^.Preceding, PData^.Size);
    AffectedPartNew^.Device^.MergeUnallocatedSpace;
  end;

begin
  LastOp := Self.GetLast^;
  // Create a new device for NewOp, which is a clone of LastOp's device
  NewOp.Kind := AKind;
  NewOp.Device := LastOp.Device^.Clone;
  NewOp.OpData := AData;
  // Find affected partition
  FindNewlyAffectedPartition;
  NewOp.AffectedPartOld := AffectedPartOld;
  NewOp.AffectedPartNew := AffectedPartNew;
  // Calculate new changes to NewOp device's partitions
  case AKind of
    okCreate:
      begin
        HandleCreate;
      end;
    okDelete:
      begin
        HandleDelete;
      end;
    okFlag:
      begin
        HandleFlag;
      end;
    okFormat:
      begin
        HandleFormat;
      end;
    okLabel:
      begin
        HandleLabel;
      end;
    okResize:
      begin
        HandleResize;
      end;
  end;
  //
  Self.Add(NewOp);
end;

function TPartedOpList.GetOpCount: LongInt;
begin
  Result := Pred(Self.Count);
end;

procedure TPartedOpList.Undo;
begin
  if Self.Count > 1 then
    Self.Remove(Pred(Self.Count));
end;

procedure TPartedOpList.Empty;
var
  I: LongInt;
begin
  for I := Pred(Self.Count) downto 1 do
  begin
    Self.Remove(I);
  end;
end;

procedure TPartedOpList.Execute;
var
  Op: TPartedOp;
  FS: TPartedFileSystem;

  procedure FileSystemCreate;
  begin
    case Op.AffectedPartNew^.FileSystem of
      'ext2', 'ext3', 'ext4':
        FS := TPartedFileSystemExt.Create;
      'fat16', 'fat32':
        FS := TPartedFileSystemFat.Create;
      'ntfs':
        FS := TPartedFileSystemNTFS.Create;
      'btrfs':
        FS := TPartedFileSystemBTRFS.Create;
      'linux-swap':
        FS := TPartedFileSystemSwap.Create;
      else
        FS := TPartedFileSystem.Create;
    end;
  end;

var
  I: LongInt;
  S: String;

begin
  WriteLog(lsInfo, Format('*** Start performing operations on %s ***', [Self.GetCurrentDevice^.Path]));
  try
    for I := 1 to Self.GetOpCount do
    begin
      S := Format(S_Executing, [I, Self.GetOpCount]);
      WriteLog(lsInfo, S);
      LoadingStart(S);
      Op := Self[I]; // Get the op we want to process
      case Op.Kind of
        okCreate:
          begin
            WriteLog(lsInfo, 'CREATE');
            FileSystemCreate;
            try
              FS.DoCreate(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
        okDelete:
          begin
            WriteLog(lsInfo, 'DELETE');
            FileSystemCreate;
            try
              FS.DoDelete(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
        okFormat:
          begin
            WriteLog(lsInfo, 'FORMAT');
            FileSystemCreate;
            try
              FS.DoFormat(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
        okFlag:
          begin
            WriteLog(lsInfo, 'FLAG');
            FileSystemCreate;
            try
              FS.DoFlag(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
        okLabel:
          begin
            WriteLog(lsInfo, 'NAME');
            FileSystemCreate;
            try
              FS.DoLabelName(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
        okResize:
          begin
            WriteLog(lsInfo, 'NAME');
            FileSystemCreate;
            try
              FS.DoResize(Op.AffectedPartNew, Op.AffectedPartOld);
            finally
              FS.Free;
            end;
          end;
      end;
    end;
  finally
    LoadingStop;
    WriteLog(lsInfo, Format('*** End performing operations on %s ***', [Self.GetCurrentDevice^.Path]));
  end;
end;

end.
