{
tparted
Copyright (C) 2024-2024 kagamma

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
}

unit FileSystem;

{$I configs.inc}

interface

uses
  Classes, SysUtils, Types, Generics.Collections,
  Parted.Commons, Parted.Devices, Parted.Operations, Parted.Partitions, Parted.Logs;

type
  TPartedFileSystem = class(TObject)
  public
    procedure DoExec(const Name: String; const Params: TStringDynArray; const Delay: LongWord = 1000);
    procedure DoMoveLeft(const PartAfter, PartBefore: PPartedPartition);
    procedure DoMoveRight(const PartAfter, PartBefore: PPartedPartition);
    procedure DoCreatePartitionOnly(const Part: PPartedPartition);

    procedure DoCreate(const PartAfter, PartBefore: PPartedPartition); virtual;
    procedure DoDelete(const PartAfter, PartBefore: PPartedPartition); virtual;
    procedure DoFormat(const PartAfter, PartBefore: PPartedPartition); virtual;
    procedure DoFlag(const PartAfter, PartBefore: PPartedPartition); virtual;
    procedure DoLabelName(const PartAfter, PartBefore: PPartedPartition); virtual;
    procedure DoResize(const PartAfter, PartBefore: PPartedPartition); virtual;
  end;
  TPartedFileSystemClass = class of TPartedFileSystem;

  TPartedFileSystemMap = specialize TDictionary<String, TPartedFileSystemClass>;
  TPartedFileSystemMinSizeMap = specialize TDictionary<String, Int64>;

procedure RegisterFileSystem(AFSClass: TPartedFileSystemClass; FileSystemTypeArray: TStringDynArray; MinSizeMap: TInt64DynArray; IsMoveable, IsShrinkable, IsGrowable: Boolean);
// Show a message box, and return false, if Size is invalid
function VerifyFileSystemMinSize(FS: String; Size: Int64): Boolean;
// Return the minimal size of file system
function GetFileSystemMinSize(FS: String): Int64;

var
  FileSystemMap: TPartedFileSystemMap;
  FileSystemMinSizeMap: TPartedFileSystemMinSizeMap;
  FileSystemFormattableArray: array of String;
  FileSystemMoveArray: array of String;
  FileSystemGrowArray: array of String;
  FileSystemShrinkArray: array of String;

implementation

uses
  UI.Commons,
  FreeVision,
  Math;

function VerifyFileSystemMinSize(FS: String; Size: Int64): Boolean;
var
  MinSize: Int64;
begin
  Result := False;
  if FileSystemMinSizeMap.ContainsKey(FS) then
  begin
    MinSize := FileSystemMinSizeMap[FS];
    if MinSize > Size then
    begin
      MsgBox(Format(S_VerifyMinSize, [FS, MinSize]), nil, mfError + mfOKButton);
    end else
    begin
      Result := True;
    end;
  end;
end;

function GetFileSystemMinSize(FS: String): Int64;
var
  MinSize: Int64;
begin
  Result := 1;
  if FileSystemMinSizeMap.ContainsKey(FS) then
  begin
    Result := FileSystemMinSizeMap[FS];
  end;
end;

procedure RegisterFileSystem(AFSClass: TPartedFileSystemClass; FileSystemTypeArray: TStringDynArray; MinSizeMap: TInt64DynArray; IsMoveable, IsShrinkable, IsGrowable: Boolean);
var
  I: LongInt;
  S: String;
  L: LongInt;
  SL: Classes.TStringList; // Ugly way to sort string...
begin
  Assert(Length(FileSystemTypeArray) = Length(MinSizeMap), 'Length must be the same!');
  SL := Classes.TStringList.Create;
  try
    SL.Sorted := True;
    for S in FileSystemFormattableArray do
      SL.Add(S);
    for I := 0 to Pred(Length(FileSystemTypeArray)) do
    begin
      S := FileSystemTypeArray[I];
      FileSystemMap.Add(S, AFSClass);
      FileSystemMinSizeMap.Add(S, MinSizeMap[I]);
      SL.Add(S);
    end;
    SetLength(FileSystemFormattableArray, SL.Count);
    for I := 0 to Pred(SL.Count) do
    begin
      FileSystemFormattableArray[I] := SL[I];
    end;
  finally
    SL.Free;
  end;
  if IsMoveable then
  begin
    L := Length(FileSystemMoveArray) + 1;
    SetLength(FileSystemMoveArray, L);
    FileSystemMoveArray[Pred(L)] := S;
  end;
  if IsShrinkable then
  begin
    L := Length(FileSystemShrinkArray) + 1;
    SetLength(FileSystemShrinkArray, L);
    FileSystemShrinkArray[Pred(L)] := S;
  end;
  if IsGrowable then
  begin
    L := Length(FileSystemGrowArray) + 1;
    SetLength(FileSystemGrowArray, L);
    FileSystemGrowArray[Pred(L)] := S;
  end;
end;

// -------------------------------

procedure TPartedFileSystem.DoExec(const Name: String; const Params: TStringDynArray; const Delay: LongWord = 1000);
var
  ExecResult: TExecResult;
begin
  Sleep(Delay);
  ExecResult := ExecS(Name, Params);
  if ExecResult.ExitCode <> 0 then
    WriteLogAndRaise(Format(S_ProcessExitCode, [Name, ExecResult.ExitCode, ExecResult.Message]));
end;

procedure TPartedFileSystem.DoCreatePartitionOnly(const Part: PPartedPartition);
var
  S: String;
begin
  S := Part^.FileSystem;
  if S = 'exfat' then // TODO: parted does not support exfat?
    S := 'fat32';
  // Create a new partition
  DoExec('/bin/parted', [Part^.Device^.Path, 'mkpart', Part^.Kind, S, IntToStr(Part^.PartStart) + 'B', IntToStr(Part^.PartEnd) + 'B']);
  // Loop through list of flags and set it
  for S in Part^.Flags do
  begin
    DoExec('/bin/parted', [Part^.Device^.Path, 'set', IntToStr(Part^.Number), S, 'on'], 16);
  end;
  // Set partition name
  if (Part^.Name <> '') and (Part^.Name <> 'primary') then
    DoExec('/bin/parted', [Part^.Device^.Path, 'name', IntToStr(Part^.Number), Part^.Name]);
end;

procedure TPartedFileSystem.DoMoveLeft(const PartAfter, PartBefore: PPartedPartition);
var
  TempPart: TPartedPartition;
begin
  TempPart := PartAfter^;
  TempPart.PartEnd := PartBefore^.PartEnd;
  TempPart.PartSize := TempPart.PartEnd - TempPart.PartStart + 1;
  // Move partition, the command with
  DoExec('/bin/sh', ['-c', Format('echo "-%dM," | sfdisk --move-data %s -N %d', [BToMBFloor(PartBefore^.PartStart - TempPart.PartStart + 1), PartAfter^.Device^.Path, PartAfter^.Number])]);
  // Calculate the shift part to determine if we need to shrink or grow later
  PartBefore^.PartEnd := PartBefore^.PartEnd - (PartBefore^.PartStart - TempPart.PartStart);
end;

procedure TPartedFileSystem.DoMoveRight(const PartAfter, PartBefore: PPartedPartition);
var
  TempPart: TPartedPartition;
begin
  TempPart := PartAfter^;
  TempPart.PartStart := PartBefore^.PartStart;
  TempPart.PartSize := TempPart.PartEnd - TempPart.PartStart + 1;
  // Move partition, the command with
  DoExec('/bin/sh', ['-c', Format('echo "+%dM," | sfdisk --move-data %s -N %d', [BToMBFloor(PartAfter^.PartStart - TempPart.PartStart + 1), PartAfter^.Device^.Path, PartAfter^.Number])]);
  // Calculate the shift part to determine if we need to shrink or grow later
  PartBefore^.PartEnd := PartBefore^.PartEnd + (PartAfter^.PartStart - TempPart.PartStart);
end;

procedure TPartedFileSystem.DoCreate(const PartAfter, PartBefore: PPartedPartition);
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoCreate');
  QueryDeviceExists(PartAfter^.Device^.Path);
  PartAfter^.Number := Abs(PartAfter^.Number);
  //
  DoCreatePartitionOnly(PartAfter);
  DoExec('/bin/wipefs', ['-a', PartAfter^.GetPartitionPath]);
end;

procedure TPartedFileSystem.DoDelete(const PartAfter, PartBefore: PPartedPartition);
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoDelete');
  QueryDeviceExists(PartBefore^.Device^.Path);
  // Make sure number is of a positive one
  if PartBefore^.Number <= 0 then
    WriteLogAndRaise(Format('Wrong number %d while trying to delete partition %s' , [PartBefore^.Number, PartBefore^.GetPartitionPath]));
  // Remove partition from partition table
  DoExec('/bin/parted', [PartBefore^.Device^.Path, 'rm', IntToStr(PartBefore^.Number)]);
end;

procedure TPartedFileSystem.DoFormat(const PartAfter, PartBefore: PPartedPartition);
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoFormat');
  QueryDeviceExists(PartAfter^.Device^.Path);
  DoExec('/bin/wipefs', ['-a', PartAfter^.GetPartitionPath]);
end;

procedure TPartedFileSystem.DoFlag(const PartAfter, PartBefore: PPartedPartition);
var
  S, State: String;
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoFlag');
  QueryDeviceExists(PartAfter^.Device^.Path);
  // Loop through list of flags and set it
  for S in FlagArray do
  begin
    if SToFlag(S, PartAfter^.Flags) <> 0 then
      State := 'on'
    else
    if SToFlag(S, PartBefore^.Flags) <> 0 then
      State := 'off'
    else
      State := '';
    if State <> '' then
      DoExec('/bin/parted', [PartAfter^.Device^.Path, 'set', IntToStr(PartAfter^.Number), S, State], 16);
  end;
end;

procedure TPartedFileSystem.DoLabelName(const PartAfter, PartBefore: PPartedPartition);
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoLabelName');
  QueryDeviceExists(PartAfter^.Device^.Path);
  if (PartAfter^.Name <> PartBefore^.Name) and (PartAfter^.Name <> '') then
    DoExec('/bin/parted', [PartAfter^.Device^.Path, 'name', IntToStr(PartAfter^.Number), PartAfter^.Name]);
end;

procedure TPartedFileSystem.DoResize(const PartAfter, PartBefore: PPartedPartition);
begin
  WriteLog(lsInfo, 'TPartedFileSystem.DoResize');
  QueryDeviceExists(PartAfter^.Device^.Path);
  // Move partition to the left or right
  if PartAfter^.PartStart < PartBefore^.PartStart then
  begin
    DoMoveLeft(PartAfter, PartBefore);
  end else
  if PartAfter^.PartStart > PartBefore^.PartStart then
  begin
    DoMoveRight(PartAfter, PartBefore);
  end;
end;

initialization
  FileSystemMap := TPartedFileSystemMap.Create;
  FileSystemMinSizeMap := TPartedFileSystemMinSizeMap.Create;

finalization
  FilesystemMap.Free;
  FileSystemMinSizeMap.Free;

end.