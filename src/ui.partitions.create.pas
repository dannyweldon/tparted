{
tparted
Copyright (C) 2024-2025 kagamma

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

unit UI.Partitions.Create;

{$I configs.inc}

interface

uses
  SysUtils, Classes, FreeVision,
  UI.Commons,
  FileSystem,
  Parted.Operations,
  Parted.Commons, Locale,
  Parted.Devices,
  Parted.Partitions;

function ShowCreateDialog(const PPart: PPartedPartition; const AData: PPartedOpDataCreate): Boolean;

implementation

function ShowCreateDialog(const PPart: PPartedPartition; const AData: PPartedOpDataCreate): Boolean;
const
  HW = 34;
var
  MX, MY: LongInt;
  R: TRect;
  D: PDialog;
  CItemRoot,
  CItem: PSItem;
  I: LongInt;
  DataOld: TPartedOpDataCreate;
  V: PView;
  Preceding,
  Size: PUIInputNumber;

  // Real-time correction for preceding
  function PrecedingMin(V: Int64): Int64;
  var
    Flooring: Int64;
  begin
    if (PPart^.Prev = nil) and (V < 1) then // A minimum of 1MB is need at the start of the disk
      Result := 1
    else
      Result := V;
  end;

  function PrecedingMax(V: Int64): Int64;
  var
    Ceiling: Int64;
  begin
    Ceiling := BToMBFloor(PPart^.PartSizeZero) - Size^.GetValue;
    if V > Ceiling then
      Result := Ceiling
    else
      Result := V;
  end;

  // Real-time correction for size
  function SizeMin(V: Int64): Int64;
  begin
    if V < 1 then
      Result := 1
    else
      Result := V;
  end;

  function SizeMax(V: Int64): Int64;
  var
    Ceiling: Int64;
  begin
    Ceiling := BToMBFloor(PPart^.PartSizeZero) - Preceding^.GetValue;
    if V > Ceiling then
      Result := Ceiling
    else
      Result := V;
  end;

begin
  Result := False;
  if PPart^.Number <> 0 then
  begin
    Exit;
  end;
  Desktop^.GetExtent(R);
  MX := R.B.X div 2;
  MY := R.B.Y div 2;
  R.Assign(MX - HW, MY - 11, MX + HW, MY + 11);
  D := New(PDialog, Init(R, S_CreateDialogTitle.ToUnicode));
  try
    D^.GetExtent(R);

    // Flags
    CItemRoot := NewSItem(FlagArray[0].ToUnicode, nil);
    CItem := CItemRoot;
    for I := 1 to High(FlagArray) do
    begin
      CItem^.Next := NewSItem(FlagArray[I].ToUnicode, nil);
      CItem := CItem^.Next;
    end;
    R.Assign(3, 2, 25, 2 + Length(FlagArray));
    V := New(PCheckBoxes, Init(R, CItemRoot));
    D^.Insert(V);
    // Flags's label
    R.Assign(3, 1, 25, 2);
    D^.Insert(New(PLabel, Init(R, S_Flags.ToUnicode, V)));

    // FileSystem
    CItemRoot := NewSItem(FileSystemFormattableArray[0].ToUnicode, nil);
    CItem := CItemRoot;
    for I := 1 to High(FileSystemFormattableArray) do
    begin
      CItem^.Next := NewSItem(FileSystemFormattableArray[I].ToUnicode, nil);
      CItem := CItem^.Next;
    end;
    R.Assign(26, 2, 45, 2 + Length(FlagArray));
    V := New(PRadioButtons, Init(R, CItemRoot));
    D^.Insert(V);
    // FileSystem's label
    R.Assign(26, 1, 45, 2);
    D^.Insert(New(PLabel, Init(R, S_FileSystem.ToUnicode, V)));

    // Free space preceding
    R.Assign(46, 2, 65, 3);
    Preceding := New(PUIInputNumber, Init(R, 16));
    Preceding^.PostfixValues := 'MGT';
    Preceding^.OnMin := @PrecedingMin;
    Preceding^.OnMax := @PrecedingMax;
    D^.Insert(Preceding);
    R.Assign(46, 1, 65, 2);
    D^.Insert(New(PLabel, Init(R, S_FreeSpacePreceding.ToUnicode, Preceding)));

    // New size
    R.Assign(46, 4, 65, 5);
    Size := New(PUIInputNumber, Init(R, 16));
    Size^.PostfixValues := 'MGT';
    Size^.OnMin := @SizeMin;
    Size^.OnMax := @SizeMax;
    D^.Insert(Size);
    R.Assign(46, 3, 65, 4);
    D^.Insert(New(PLabel, Init(R, S_NewSize.ToUnicode, Size)));

    // Total size
    R.Assign(47, 5, 65, 7);
    D^.Insert(New(PStaticText, Init(R, Format(S_MaxPossibleSpace, [BToMBFloor(PPart^.PartSizeZero)]).ToUnicode)));

    // Label
    R.Assign(46, 9, 65, 10);
    V := New(PUIInputLine, Init(R, 16));
    D^.Insert(V);
    R.Assign(46, 8, 65, 9);
    D^.Insert(New(PLabel, Init(R, S_Label.ToUnicode, V)));

    // Name
    R.Assign(46, 11, 65, 12);
    V := New(PUIInputLine, Init(R, 16));
    D^.Insert(V);
    R.Assign(46, 10, 65, 11);
    D^.Insert(New(PLabel, Init(R, S_Name.ToUnicode, V)));

    // Ok-Button
    R.Assign(HW + HW - 14, 17, HW + HW - 2, 19);
    D^.Insert(New(PUIButton, Init(R, S_OkButton.ToUnicode, cmOK, bfDefault)));

    // Cancel-Button
    R.Assign(HW + HW - 14, 19, HW + HW - 2, 21);
    D^.Insert(New(PUIButton, Init(R, S_CancelButton.ToUnicode, cmCancel, bfDefault)));

    D^.FocusNext(False);

    DataOld := AData^;
    D^.SetData(AData^);
    if Desktop^.ExecView(D) = cmOk then
    begin
      D^.GetData(AData^);
      Result := VerifyFileSystemSize(PPart^.Device^.Table, FileSystemFormattableArray[AData^.FileSystem], AData^.Size);
    end;
  finally
    Dispose(D, Done);
  end;
end;

end.

