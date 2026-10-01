#Region Internal

#Region Subscriptions

// Subscription. BeforeWrite.
//
// 	Ru: Подписка. ПередЗаписью.
//
// Parameters:
//  DocumentObject - DocumentObject - The document being written.
//                                    Ru: Записываемый документ.
//  Cancel - Boolean - Write cancel flag (not used by the control system).
//                     Ru: Признак отказа от записи (системой контроля не используется).
//  WriteMode - DocumentWriteMode - Write mode of the current write.
//                                  Ru: Режим записи.
//  PostingMode - DocumentPostingMode - Posting mode of the current write.
//                                      Ru: Режим проведения.
Procedure BalanceControl_Documents_BeforeWrite(DocumentObject, Cancel, WriteMode, PostingMode) Export

	SetPrivilegedMode(True);

	ClearAdditionalProperties(DocumentObject);

	If DocumentObject.DataExchange.Load Or IsOff() Or WriteMode = DocumentWriteMode.Write Then
		Return;
	EndIf;

	ControlRequired = True;
	BalanceControlOverridable.OnDefineControlRequired(DocumentObject, ControlRequired);
	If Not ControlRequired Then
		Return;
	EndIf;

	AddOldAccumulationRegistersAndMetadata(DocumentObject);
	OldDate = ?(DocumentObject.IsNew(), DocumentObject.Date, _ObjectAttributeValue(DocumentObject.Ref, "Date"));
	DocumentObject.AdditionalProperties.Insert(NameOldDate(), OldDate);
	DocumentObject.AdditionalProperties.Insert(NameDetailWriteMode(), DetailWriteMode(DocumentObject, WriteMode));

	SetPrivilegedMode(False);

EndProcedure

// Subscription. OnWrite.
//
// 	Ru: Подписка. ПриЗаписи.
//
// Parameters:
//  DocumentObject - DocumentObject - The document being written.
//                                    Ru: Записываемый документ.
//  Cancel - Boolean - Write cancel flag (not used by the control system).
//                     Ru: Признак отказа от записи (системой контроля не используется).
Procedure BalanceControl_Documents_OnWrite(DocumentObject, Cancel) Export

	SetPrivilegedMode(True);

	If DocumentObject.DataExchange.Load Or IsOff() Then
		Return;
	EndIf;

	DetailWriteModeData = Undefined;
	If Not DocumentObject.AdditionalProperties.Property(NameDetailWriteMode(), DetailWriteModeData) Then
		Return;
	EndIf;

	If DetailWriteModeData.IsUndoPosting Then

		WriteControlledRecordSets(DocumentObject);
		BalanceProcessor(DocumentObject);

	EndIf;

	SetPrivilegedMode(False);

EndProcedure

// Subscription. BeforePosting. (After)
//
// 	Ru: Подписка. ПередПроведением. (После)
//
// Parameters:
//  DocumentObject - DocumentObject - The document being posted.
//                                    Ru: Проводимый документ.
//  Cancel - Boolean - Posting cancel flag (not used by the control system).
//                     Ru: Признак отказа от проведения (системой контроля не используется).
//  PostingMode - DocumentPostingMode - Posting mode of the current write.
//                                      Ru: Режим проведения.
Procedure BalanceControl_Documents_Posting(DocumentObject, Cancel, PostingMode) Export

	SetPrivilegedMode(True);

	If DocumentObject.DataExchange.Load Or IsOff() Then
		Return;
	EndIf;

	If Not DocumentObject.AdditionalProperties.Property(NameRegistersData()) Then
		Return;
	EndIf;

	WriteControlledRecordSets(DocumentObject);
	BalanceProcessor(DocumentObject);

	SetPrivilegedMode(False);

EndProcedure

#EndRegion

#EndRegion

#Region Private

#Region SystemDisabler

// Checks if the balance control system is disabled.
//
// 	Ru: Проверяет, что система контроля остатков выключена.
//
// Returns:
//  Boolean - True if the system is disabled, otherwise False.
//            Ru: Истина, если система выключена, иначе Ложь.
Function IsOff()

	Return Constants.DisableBalanceControlSystem.Get();

EndFunction

#EndRegion

#Region InitializeDataProcessor

// Populates additional properties of the object with data from accumulation registers under control,
// including their dimensions, resources, and old records.
//
// 	Ru: Заполняет дополнительные свойства объекта данными из регистров накопления,
// находящихся под контролем, включая их измерения, ресурсы и старые движения.
//
// Parameters:
//  Object - DocumentObject - The object whose register records are processed and additional properties are populated.
//                            Ru: Обрабатываемый документ; его дополнительные свойства заполняются данными контроля.
//
//@skip-check query-in-loop
Procedure AddOldAccumulationRegistersAndMetadata(Object)

	RegistersData = New Array;
	RegisterUnderControlTypes = Metadata.DefinedTypes.RegistersUnderControl.Type;

	For Each Register In Object.RegisterRecords Do

		If Not RegisterUnderControlTypes.ContainsType(TypeOf(Register)) Then
			Continue;
		EndIf;

		RegisterMetadata = Register.Metadata();
		CheckRegisterIsControllable(RegisterMetadata);

		Data = New Structure;

		Dimensions = New Array;
		For Each Dimension In RegisterMetadata.Dimensions Do
			Dimensions.Add(Dimension.Name);
		EndDo;

		Resources = New Array;
		For Each Resource In RegisterMetadata.Resources Do
			Resources.Add(Resource.Name);
		EndDo;

		BalanceControlOverridable.OnDefineControlledResources(Object, RegisterMetadata, Resources);
		ValidateControlledResources(RegisterMetadata, Resources);

		Data.Insert("Dimensions", Dimensions);
		Data.Insert("Resources", Resources);
		Data.Insert("Name", RegisterMetadata.Name);
		Data.Insert("FullName", RegisterMetadata.FullName());

		SortMetadataByClusterIndex(Data);

		OldRecords_Expense = DocumentRecords(Object.Ref, Data, AccumulationRecordType.Expense);
		OldRecords_Receipt = DocumentRecords(Object.Ref, Data, AccumulationRecordType.Receipt);
		ReverseRecordsBetweenTwoTables(OldRecords_Expense, OldRecords_Receipt, Resources);

		Data.Insert(NameOldRecordsExpense(), OldRecords_Expense);
		Data.Insert(NameOldRecordsReceipt(), OldRecords_Receipt);

		RegistersData.Add(Data);
	EndDo;

	Object.AdditionalProperties.Insert(NameRegistersData(), RegistersData);

EndProcedure

// Validates that a register from the RegistersUnderControl defined type can actually be
// controlled: it must be a balance accumulation register with at least one dimension.
// Raises a sentinel error otherwise.
//
// 	Ru: Проверяет, что регистр из определяемого типа RegistersUnderControl действительно
// может контролироваться: это должен быть регистр накопления остатков хотя бы
// с одним измерением. Иначе вызывает исключение с описанием причины.
//
// Parameters:
//  RegisterMetadata - MetadataObject - Accumulation register metadata.
//                                      Ru: Метаданные регистра накопления.
Procedure CheckRegisterIsControllable(RegisterMetadata)

	If RegisterMetadata.RegisterType <> Metadata.ObjectProperties.AccumulationRegisterType.Balance Then
		Raise StrTemplate(NStr(
			"ru = 'Система контроля остатков: регистр %1 не может контролироваться - это не регистр остатков.';
			|en = 'Balance control system: register %1 cannot be controlled - it is not a balance register.'"),
			RegisterMetadata.FullName());
	EndIf;

	If RegisterMetadata.Dimensions.Count() = 0 Then
		Raise StrTemplate(NStr(
			"ru = 'Система контроля остатков: регистр %1 не может контролироваться - у него нет измерений.';
			|en = 'Balance control system: register %1 cannot be controlled - it has no dimensions.'"),
			RegisterMetadata.FullName());
	EndIf;

EndProcedure

// Clears the resource list after the overridable hook: names the register does not have
// are discarded, an empty list is a configuration error - turning a register off is done
// through the defined type, not through an empty resource list.
//
// 	Ru: Чистит список ресурсов после переопределяемого метода: имена, которых у регистра нет,
// отбрасываются, пустой список - ошибка конфигурирования: выключение регистра делается
// через определяемый тип, а не через пустой список ресурсов.
//
// Parameters:
//  RegisterMetadata - MetadataObject - Accumulation register metadata.
//                                      Ru: Метаданные регистра накопления.
//  Resources - Array of String - Controlled resource names after the hook. Replaced in place.
//                                Ru: Имена контролируемых ресурсов после переопределяемого метода.
//                                Недопустимые имена удаляются из массива.
Procedure ValidateControlledResources(RegisterMetadata, Resources)

	ValidResources = New Array;
	For Each ResourceName In Resources Do
		If RegisterMetadata.Resources.Find(ResourceName) <> Undefined Then
			ValidResources.Add(ResourceName);
		EndIf;
	EndDo;

	If ValidResources.Count() = 0 Then
		Raise StrTemplate(NStr(
			"ru = 'Система контроля остатков: у регистра %1 после переопределения не осталось контролируемых ресурсов.';
			|en = 'Balance control system: register %1 has no controlled resources left after overriding.'"),
			RegisterMetadata.FullName());
	EndIf;

	Resources = ValidResources;

EndProcedure

// Reads the document records from the database for one register and record type.
// Only the columns the control needs are selected: record type, dimensions and resources.
// Only active records are read - inactive ones do not feed the balance totals.
//
// 	Ru: Читает движения документа по одному регистру и виду движения из базы.
// Выбираются только нужные контролю колонки: вид движения, измерения и ресурсы.
// Читаются только активные движения - неактивные не влияют на итоги остатков.
//
// Parameters:
//  Ref - DocumentRef - Recorder reference.
//                      Ru: Ссылка на регистратор.
//  RegisterData - Structure - Register data with the FullName, Dimensions and Resources properties.
//                             Ru: Данные регистра со свойствами FullName, Dimensions и Resources.
//  RecordType - AccumulationRecordType, Undefined - Record type filter; Undefined = both types.
//                                                   Ru: Отбор по виду движения; Неопределено = оба вида.
//
// Returns:
//  ValueTable - Document records: RecordType, dimensions and resources columns.
//               Ru: Движения документа: колонки RecordType, измерения и ресурсы.
Function DocumentRecords(Ref, RegisterData, RecordType = Undefined)

	If RecordType = Undefined Then
		RecordType = New Array;
		RecordType.Add(AccumulationRecordType.Receipt);
		RecordType.Add(AccumulationRecordType.Expense);
	EndIf;

	SelectedFields = New Array;
	SelectedFields.Add("RecordType");
	_SupplementArray(SelectedFields, RegisterData.Dimensions);
	_SupplementArray(SelectedFields, RegisterData.Resources);

	Query = New Query;
	Query.Text =
	"SELECT
	|	&SelectedFields
	|FROM
	|	&RegisterFullName AS RecordActions
	|WHERE
	|	RecordActions.Recorder = &Recorder
	|	AND RecordActions.Active
	|	AND RecordActions.RecordType IN (&RecordType)";
	Query.Text = StrReplace(Query.Text, "&SelectedFields", AliasedFields(SelectedFields, "RecordActions"));
	Query.Text = StrReplace(Query.Text, "&RegisterFullName", RegisterData.FullName);

	Query.SetParameter("Recorder", Ref);
	Query.SetParameter("RecordType", RecordType);

	Return Query.Execute().Unload();

EndFunction

// Determines the write mode details for a document based on its current state and write mode.
//
// 	Ru: Определяет детали режима записи документа на основании его текущего состояния и заданного режима записи.
//
// Parameters:
//  Object - DocumentObject - The document object being processed.
//                            Ru: Обрабатываемый объект документа.
//  WriteMode - DocumentWriteMode - The write mode being applied to the document.
//                                  Ru: Применяемый режим записи.
//
// Returns:
//  Structure - A structure containing flags for IsUndoPosting, IsReposting, and IsPosting.
//              Ru: Структура с флагами IsUndoPosting, IsReposting и IsPosting.
Function DetailWriteMode(Object, WriteMode)

	DetailWriteModeData = New Structure("IsUndoPosting, IsReposting, IsPosting", WriteMode
		= DocumentWriteMode.UndoPosting, False, False);

	If WriteMode = DocumentWriteMode.Posting Then
		DetailWriteModeData.IsReposting = Object.Posted;
		DetailWriteModeData.IsPosting = Not Object.Posted;
	EndIf;

	Return DetailWriteModeData;

EndFunction

#EndRegion

#Region CoreProcessor

// Writes the record sets of the controlled registers, so that by the time the balance is read the
// movements are already in the database for comparison.
//
// 	Ru: Записывает наборы движений контролируемых регистров, чтобы к моменту чтения остатков движения
// уже были в базе для сравнения.
//
// Parameters:
//  DocumentObject - DocumentObject - The document being written.
//                                    Ru: Записываемый документ.
Procedure WriteControlledRecordSets(DocumentObject)

	For Each RegisterData In DocumentObject.AdditionalProperties[NameRegistersData()] Do
		RecordSet = DocumentObject.RegisterRecords[RegisterData.Name];
		RecordSet.LockForUpdate = True;
		RecordSet.Write();
	EndDo;

EndProcedure

// Processes balance control for the specified object, checking registers for expense and receipt
// records that need the check, and handles the errors.
//
// 	Ru: Выполняет контроль остатков для указанного объекта: проверяет движения расхода и прихода
// по каждому контролируемому регистру и обрабатывает возникающие ошибки.
//
// Parameters:
//  Object - DocumentObject - The document being processed.
//                            Ru: Обрабатываемый документ.
Procedure BalanceProcessor(Object)

	GlobalErrors = New Array;
	NewDate = ?(ValueIsFilled(Object.Date), Object.Date, CurrentSessionDate());
	DetailWriteModeData = Object.AdditionalProperties[NameDetailWriteMode()];
	OldDate = Object.AdditionalProperties[NameOldDate()];

	For Each RegisterData In Object.AdditionalProperties[NameRegistersData()] Do

		NewRecords = Object.RegisterRecords[RegisterData.Name].Unload();
		NewRecords_Expense = NewRecords.Copy(New Structure("RecordType", AccumulationRecordType.Expense));
		NewRecords_Receipt = NewRecords.Copy(New Structure("RecordType", AccumulationRecordType.Receipt));

		ReverseRecordsBetweenTwoTables(NewRecords_Expense, NewRecords_Receipt, RegisterData.Resources);

		ErrorsExpense = CheckBalanceExpense(RegisterData, NewRecords_Expense, DetailWriteModeData, OldDate, NewDate);
		ErrorsReceipt = CheckBalanceReceipt(RegisterData, NewRecords_Receipt, DetailWriteModeData, OldDate, NewDate);

		_SupplementArray(GlobalErrors, ErrorsExpense);
		_SupplementArray(GlobalErrors, ErrorsReceipt);

	EndDo;

	ErrorsProcessing(GlobalErrors, Object);

EndProcedure

// Checks balance for expense records and validates constraints based on
// register data and date ranges (case-based approach).
//
// 	Ru: Проверяет остатки по движениям расхода; набор проверок зависит от режима записи
// и соотношения дат (кейсовый подход).
//
// Parameters:
//  RegisterData - Structure - Contains register records and metadata.
//                             Ru: Данные регистра: движения и метаданные.
//  NewRecords - ValueTable - List of new expense records to validate.
//                            Ru: Новые движения расхода для проверки.
//  DetailWriteModeData - Structure - Defines write mode (e.g., reposting, undo).
//                                    Ru: Детали режима записи (проведение, перепроведение, отмена проведения).
//  OldDate - Date - Previous date for comparison.
//                   Ru: Дата прошлой версии документа.
//  NewDate - Date - Current date for comparison.
//                   Ru: Новая дата документа.
//
// Returns:
//  Array of Structure - List of validation errors for expense records.
//                       Ru: Ошибки проверки по движениям расхода.
Function CheckBalanceExpense(RegisterData, NewRecords, DetailWriteModeData, OldDate, NewDate)

	SmallerDate = ?(NewDate >= OldDate, OldDate, NewDate);

	ErrorsExpense = New Array;

	If DetailWriteModeData.IsUndoPosting Then
		Return ErrorsExpense;
	EndIf;

	ExpenseLessStockTable = LessStockTable(RegisterData, RegisterData[NameOldRecordsExpense()], NewRecords);
	UniqueKeysTable = UniqueStocksTable(RegisterData, NewRecords, RegisterData[NameOldRecordsExpense()]);

	If ExpenseLessStockTable.Count() > 0 And DetailWriteModeData.IsReposting Then

		ErrorsExpense = EnoughStock(RegisterData, UniqueKeysTable, SmallerDate);

	ElsIf ExpenseLessStockTable.Count() = 0 And DetailWriteModeData.IsReposting And (NewDate < OldDate) Then

		ErrorsExpense = EnoughStock(RegisterData, UniqueKeysTable, NewDate);

	ElsIf DetailWriteModeData.IsPosting Then

		ErrorsExpense = EnoughStock(RegisterData, UniqueKeysTable, SmallerDate);

	EndIf;

	Return ErrorsExpense;

EndFunction

// Checks the stock balance for receipt operations and returns any errors found (case-based approach).
//
// 	Ru: Проверяет остатки по движениям прихода; набор проверок зависит от режима записи
// и соотношения дат (кейсовый подход).
//
// Parameters:
//  RegisterData - Structure - Data structure containing register records.
//                             Ru: Данные регистра: движения и метаданные.
//  NewRecords - ValueTable - Table with new receipt records.
//                            Ru: Новые движения прихода для проверки.
//  DetailWriteModeData - Structure - Write mode for the operation (e.g., posting, undo posting).
//                                    Ru: Детали режима записи (проведение, перепроведение, отмена проведения).
//  OldDate - Date - Original date of the operation.
//                   Ru: Дата прошлой версии документа.
//  NewDate - Date - New date for the operation.
//                   Ru: Новая дата документа.
//
// Returns:
//  Array of Structure - Array of errors found during stock balance check.
//                       Ru: Ошибки проверки по движениям прихода.
Function CheckBalanceReceipt(RegisterData, NewRecords, DetailWriteModeData, OldDate, NewDate)

	SmallerDate = ?(NewDate >= OldDate, OldDate, NewDate);

	ErrorsReceipt = New Array;

	ReceiptLessStockTable = LessStockTable(RegisterData, NewRecords, RegisterData[NameOldRecordsReceipt()]);
	UniqueKeysTable = UniqueStocksTable(RegisterData, NewRecords, RegisterData[NameOldRecordsReceipt()]);

	If DetailWriteModeData.IsPosting Then
		Return ErrorsReceipt;
	ElsIf DetailWriteModeData.IsUndoPosting Then
		ErrorsReceipt = EnoughStock(RegisterData, UniqueKeysTable, SmallerDate);
	Else // IsReposting

		If ReceiptLessStockTable.Count() = 0 And (NewDate > OldDate) Then
			ErrorsReceipt = EnoughStock(RegisterData, UniqueKeysTable, OldDate);

		ElsIf ReceiptLessStockTable.Count() > 0 Then
			ErrorsReceipt = EnoughStock(RegisterData, UniqueKeysTable, SmallerDate);
		EndIf;

	EndIf;

	Return ErrorsReceipt;

EndFunction

#EndRegion

#Region TableDataProcessor

#Region ReverseRecords

// Reverses records between two tables in both directions using specified resources.
//
// 	Ru: Обрабатывает сторнирующие движения у обеих таблиц, используя ресурсы.
//
// Parameters:
//  SourceTable - ValueTable - The first table to process records from.
//                             Ru: Первая обрабатываемая таблица.
//  DestinationTable - ValueTable - The second table to process records from.
//                                  Ru: Вторая обрабатываемая таблица.
//  Resources - Array of String - Resources used during the reversal process.
//                                Ru: Ресурсы, участвующие в сторнировании.
Procedure ReverseRecordsBetweenTwoTables(SourceTable, DestinationTable, Resources)

	ReversalRecordsProcessor(SourceTable, DestinationTable, Resources);
	ReversalRecordsProcessor(DestinationTable, SourceTable, Resources);

EndProcedure

// Processes reversal records by moving negative values from source rows to destination rows.
//
// 	Ru: Обрабатывает сторнирующие движения, создавая противоположные движения с другим видом движения.
//
// Parameters:
//  SourceTable - ValueTable - Table containing source records to process.
//                             Ru: Таблица с исходными записями.
//  DestinationTable - ValueTable - Table where reversal records will be added.
//                                  Ru: Таблица, в которую добавляются сторно-записи.
//  Resources - Array of String - Collection of resource fields to check for negative values.
//                                Ru: Ресурсы, проверяемые на отрицательные значения.
Procedure ReversalRecordsProcessor(SourceTable, DestinationTable, Resources)

	ClearRows = New Array;

	For Each SourceRow In SourceTable Do
		IsReversal = False;
		DeleteClearRow = True;
		StructureForFillingReverseRow = New Structure;

		For Each Resource In Resources Do

			If SourceRow[Resource] = Undefined Then
				SourceRow[Resource] = 0;
				Continue;
			ElsIf SourceRow[Resource] < 0 Then
				IsReversal = True;
				StructureForFillingReverseRow.Insert(Resource, -SourceRow[Resource]);
				SourceRow[Resource] = 0;
			Else
				DeleteClearRow = False;
			EndIf;

		EndDo;

		If IsReversal Then
			ReverseRow = DestinationTable.Add();

			FillPropertyValues(ReverseRow, SourceRow, , StrConcat(Resources, ", "));
			FillPropertyValues(ReverseRow, StructureForFillingReverseRow);

			ReverseRow["RecordType"] = ?(ReverseRow["RecordType"] = AccumulationRecordType.Expense,
				AccumulationRecordType.Receipt, AccumulationRecordType.Expense);

			If DeleteClearRow Then
				ClearRows.Add(SourceRow);
			EndIf;
		EndIf;

	EndDo;

	For Each Row In ClearRows Do
		SourceTable.Delete(Row);
	EndDo;

EndProcedure

#EndRegion

// Processes and filters stock records to identify items with reduced quantities.
//
// 	Ru: Обрабатывает и фильтрует движения, выявляя позиции, по которым остаток уменьшается.
//
// Parameters:
//  RegisterData - Structure - Contains metadata for the register, including resources and dimensions.
//                             Ru: Метаданные регистра: ресурсы и измерения.
//  NewRecords - ValueTable - New records to be processed, with quantities negated.
//                            Ru: Новые движения; значения их ресурсов меняются на противоположные.
//  OldRecords - ValueTable - Existing records that will be updated and filtered.
//                            Ru: Старые движения; таблица изменяется и фильтруется.
//
// Returns:
//  ValueTable - Filtered records showing only items with reduced stock.
//               Ru: Строки, по которым остаток уменьшается.
Function LessStockTable(RegisterData, NewRecords, OldRecords)

	For Each Row In NewRecords Do

		For Each Resource In RegisterData.Resources Do

			If TypeOf(Row[Resource]) = Type("Number") Then
				Row[Resource] = -Row[Resource];
			EndIf;

		EndDo;

		NewRow = OldRecords.Add();
		FillPropertyValues(NewRow, Row);

	EndDo;

	OldRecords.GroupBy(StrConcat(RegisterData.Dimensions, ","), StrConcat(RegisterData.Resources, ","));

	DeleteRows = New Array;

	For Each Row In OldRecords Do
		LessStock = False;

		For Each Resource In RegisterData.Resources Do

			If TypeOf(Row[Resource]) = Type("Number") And Row[Resource] > 0 Then
				LessStock = True;
			EndIf;

		EndDo;

		If Not LessStock Then
			DeleteRows.Add(Row);
		EndIf;

	EndDo;

	For Each Row In DeleteRows Do
		OldRecords.Delete(Row);
	EndDo;

	Return OldRecords;

EndFunction

// Group records from NewRecords and OldRecords by dimensions and resources from RegisterData.
// Called after LessStockTable, so both tables come already changed by it: only the dimension
// key columns of the result are meaningful.
//
// 	Ru: Группирует движения из новых (NewRecords) и старых (OldRecords) данных по измерениям
// и ресурсам из данных регистра (RegisterData).
// Вызывается после LessStockTable, поэтому обе таблицы приходят уже измененными ею:
// осмысленны только колонки ключей измерений результата.
//
// Parameters:
//  RegisterData - Structure - Contains dimensions and resources of the register.
//                             Ru: Измерения и ресурсы регистра.
//  NewRecords - ValueTable - New records to be added.
//                            Ru: Новые движения.
//  OldRecords - ValueTable - Existing records to be filtered.
//                            Ru: Старые движения.
//
// Returns:
//  ValueTable - Grouped union of both tables; only the dimension key columns are meaningful.
//               Ru: Свернутое объединение обеих таблиц; осмысленны только колонки ключей измерений.
Function UniqueStocksTable(RegisterData, NewRecords, OldRecords)

	AllRecords = OldRecords.Copy();

	For Each Row In NewRecords Do

		NewRow = AllRecords.Add();
		FillPropertyValues(NewRow, Row);

	EndDo;

	AllRecords.GroupBy(StrConcat(RegisterData.Dimensions, ","), StrConcat(RegisterData.Resources, ","));

	Return AllRecords;

EndFunction

// Checks if there is enough stock and collects errors for insufficient stock records.
// For every (dimension key, resource) pair the earliest negative point is reported.
//
// 	Ru: Проверяет достаточность остатков и собирает ошибки по точкам нехватки.
// Для каждой пары (ключ измерений, ресурс) сообщается самая ранняя точка минуса.
//
// Parameters:
//  RecordsMetadata - Structure - Metadata for records.
//                                Ru: Метаданные регистра.
//  UniqueKeys - ValueTable - Unique dimension keys to check.
//                            Ru: Уникальные ключи измерений для проверки.
//  StartOfPeriod - Date - Start of the check period.
//                         Ru: Начало периода проверки.
//  EndOfPeriod - Date, Undefined - End of the check period; Undefined = unbounded.
//                                  Ru: Конец периода проверки; Неопределено = без границы.
//
// Returns:
//  Array of Structure - List of errors found.
//                       Ru: Найденные ошибки.
Function EnoughStock(RecordsMetadata, UniqueKeys, StartOfPeriod, EndOfPeriod = Undefined)

	Errors = New Array;

	If UniqueKeys.Count() = 0 Then
		Return Errors;
	EndIf;

	NegativeBalances = NegativeBalancesTable(RecordsMetadata, UniqueKeys, StartOfPeriod, EndOfPeriod);

	DimensionsColumns = StrConcat(RecordsMetadata.Dimensions, ",");
	ReportedPairs = NegativeBalances.CopyColumns(DimensionsColumns);
	ReportedPairs.Columns.Add("ResourceName", New TypeDescription("String"));
	ReportedPairs.Indexes.Add(DimensionsColumns + ",ResourceName");

	For Each ResultRow In NegativeBalances Do

		DimensionKey = New Structure;
		PairFilter = New Structure;
		For Each Dimension In RecordsMetadata.Dimensions Do
			DimensionKey.Insert(Dimension, ResultRow[Dimension]);
			PairFilter.Insert(Dimension, ResultRow[Dimension]);
		EndDo;
		PairFilter.Insert("ResourceName", "");

		For Each Resource In RecordsMetadata.Resources Do

			ResourceValue = ?(ValueIsFilled(ResultRow[Resource]), ResultRow[Resource], 0);
			If ResourceValue >= 0 Then
				Continue;
			EndIf;

			PairFilter.ResourceName = Resource;
			If ReportedPairs.FindRows(PairFilter).Count() > 0 Then
				Continue;
			EndIf;

			ReportedPair = ReportedPairs.Add();
			FillPropertyValues(ReportedPair, PairFilter);

			Error = New Structure;
			Error.Insert("Resource", Resource);
			Error.Insert("Date", ResultRow.Date);
			Error.Insert("Result", ResultRow[Resource]);
			Error.Insert("StructureForLogs", StructureToString(DimensionKey));
			Errors.Add(Error);
		EndDo;
	EndDo;

	Return Errors;

EndFunction

#EndRegion

#Region StockProcessor

// Runs the batch balance query: all unique dimension keys are checked by a single query
// to the BalanceAndTurnovers virtual table with the Second periodicity.
//
// 	Ru: Выполняет пакетный запрос остатков: все уникальные ключи измерений проверяются одним
// запросом к виртуальной таблице ОстаткиИОбороты с периодичностью Секунда.
//
// Parameters:
//  RecordsMetadata - Structure - Contains dimensions, resources and full name of the register.
//                                Ru: Измерения, ресурсы и полное имя регистра.
//  KeysTable - ValueTable - Unique dimension keys (extra columns are ignored).
//                           Ru: Уникальные ключи измерений (лишние колонки игнорируются).
//  StartOfPeriod - Date - Start of period.
//                         Ru: Начало периода.
//  EndOfPeriod - Date, Undefined - End of period; Undefined = unbounded window.
//                                  Ru: Конец периода; Неопределено = окно без правой границы.
//
// Returns:
//  ValueTable - Negative balance points (Date, dimensions, resource closing balances),
//               ordered by period ascending.
//               Ru: Точки отрицательных остатков (дата, измерения, конечные остатки ресурсов)
//               в порядке возрастания периода.
Function NegativeBalancesTable(RecordsMetadata, KeysTable, StartOfPeriod, EndOfPeriod)

	DimensionsColumns = StrConcat(RecordsMetadata.Dimensions, ",");
	UniqueKeys = KeysTable.Copy( , DimensionsColumns);
	UniqueKeys.GroupBy(DimensionsColumns);

	Query = New Query;
	Query.Text = NegativeBalancesQueryText(RecordsMetadata);

	Query.SetParameter("KeysTable", UniqueKeys);
	Query.SetParameter("FirstDimensionValues", _UnloadColumn(UniqueKeys, RecordsMetadata.Dimensions[0], True));
	Query.SetParameter("StartOfPeriod", StartOfPeriod);
	Query.SetParameter("EndOfPeriod", EndOfPeriod);

	Return Query.Execute().Unload();

EndFunction

// Assembles the text of the batch balance query. Depends on the register metadata only.
// The [Name] placeholders are text macros, the &Name entries are query parameters.
// The FirstDimension condition in the virtual table parameters is there for the DBMS optimizer.
//
// 	Ru: Собирает текст пакетного запроса остатков. Зависит только от метаданных регистра.
// Подстановки [Имя] - макросы текста, конструкции &Имя - параметры запроса.
// Условие в виртуальной таблице по FirstDimension сделано из-за особенностей работы оптимизатора СУБД.
//
// Parameters:
//  RecordsMetadata - Structure - Contains dimensions, resources and full name of the register.
//                                Ru: Измерения, ресурсы и полное имя регистра.
//
// Returns:
//  String - Query text ready to be executed.
//           Ru: Готовый к выполнению текст запроса.
Function NegativeBalancesQueryText(RecordsMetadata)

	QueryTemplate =
	"SELECT
	|	[KeysFields]
	|INTO ttKeys
	|FROM
	|	&KeysTable AS KeysTable
	|INDEX BY
	|	[FirstDimension]
	|;
	|SELECT TOP [MaxPoints]
	|	MainRegister.Period AS Date,
	|	[DimensionFields],
	|	[ResourceFields]
	|FROM
	|	[RegisterFullName].BalanceAndTurnovers(
	|			&StartOfPeriod, &EndOfPeriod, Second,, [FirstDimension] IN (&FirstDimensionValues)) AS MainRegister
	|		INNER JOIN ttKeys AS Filter
	|		ON [JoinConditions]
	|WHERE
	|	[NegativeBalanceCondition]
	|ORDER BY
	|	Date";

	QueryMacros = New Structure;
	QueryMacros.Insert("KeysFields", AliasedFields(RecordsMetadata.Dimensions, "KeysTable"));
	QueryMacros.Insert("FirstDimension", RecordsMetadata.Dimensions[0]);
	QueryMacros.Insert("MaxPoints", Format(MaxNegativePointsCount(), "NZ=0; NG="));
	QueryMacros.Insert("DimensionFields", AliasedFields(RecordsMetadata.Dimensions, "MainRegister"));
	QueryMacros.Insert("ResourceFields", ClosingBalanceFields(RecordsMetadata.Resources));
	QueryMacros.Insert("RegisterFullName", RecordsMetadata.FullName);
	QueryMacros.Insert("JoinConditions", JoinConditions(RecordsMetadata.Dimensions, "MainRegister", "Filter"));
	QueryMacros.Insert("NegativeBalanceCondition", NegativeBalanceCondition(RecordsMetadata.Resources));

	Return _InsertParametersIntoString(QueryTemplate, QueryMacros);

EndFunction

// Builds a field list of the form "Prefix.Name AS Name".
//
// 	Ru: Формирует список полей вида "Префикс.Имя AS Имя".
//
// Parameters:
//  FieldNames - Array of String - Field names.
//                                 Ru: Имена полей.
//  TablePrefix - String - Table alias to prefix the fields with.
//                         Ru: Псевдоним таблицы для префикса полей.
//
// Returns:
//  String - Comma-separated field list for the query.
//           Ru: Список полей через запятую для запроса.
Function AliasedFields(FieldNames, TablePrefix)

	Separator = ", ";
	ResultStringForQuery = New Array;

	For Each FieldName In FieldNames Do
		ResultStringForQuery.Add(StrTemplate("%1.%2 AS %2", TablePrefix, FieldName));
	EndDo;

	Return StrConcat(ResultStringForQuery, Separator);

EndFunction

// Builds a string of closing balance fields for the query.
//
// 	Ru: Формирует строку полей конечных остатков для запроса.
//
// Parameters:
//  Resources - Array of String - List of resource names to include in the query string.
//                                Ru: Имена ресурсов для включения в текст запроса.
//
// Returns:
//  String - Concatenated string of resource fields for the query.
//           Ru: Строка полей конечных остатков для запроса.
Function ClosingBalanceFields(Resources)

	Separator = ", ";
	ResultStringForQuery = New Array;

	For Each Resource In Resources Do
		ResultStringForQuery.Add(StrTemplate("MainRegister.%1ClosingBalance AS %1", Resource));
	EndDo;

	Return StrConcat(ResultStringForQuery, Separator);

EndFunction

// Builds a join condition list of the form "Left.Name = Right.Name AND ...".
//
// 	Ru: Формирует список условий соединения вида "Левый.Имя = Правый.Имя И ...".
//
// Parameters:
//  FieldNames - Array of String - Field names.
//                                 Ru: Имена полей.
//  LeftPrefix - String - Alias of the left table.
//                        Ru: Псевдоним левой таблицы.
//  RightPrefix - String - Alias of the right table.
//                         Ru: Псевдоним правой таблицы.
//
// Returns:
//  String - Join conditions for the query.
//           Ru: Условия соединения для запроса.
Function JoinConditions(FieldNames, LeftPrefix, RightPrefix)

	Separator = Chars.LF + "			AND ";
	ResultStringForQuery = New Array;

	For Each FieldName In FieldNames Do
		ResultStringForQuery.Add(StrTemplate("%1.%3 = %2.%3", LeftPrefix, RightPrefix, FieldName));
	EndDo;

	Return StrConcat(ResultStringForQuery, Separator);

EndFunction

// Builds the condition matching a row where at least one resource went negative.
//
// 	Ru: Формирует условие отбора строки, в которой хотя бы один ресурс ушел в минус.
//
// Parameters:
//  Resources - Array of String - List of resource field names to check for negative closing balances.
//                                Ru: Имена ресурсов, проверяемых на отрицательный конечный остаток.
//
// Returns:
//  String - Concatenated WHERE clause condition for the query.
//           Ru: Условие для секции ГДЕ запроса.
Function NegativeBalanceCondition(Resources)

	Separator = " OR ";
	ResultStringForQuery = New Array;

	For Each Resource In Resources Do
		ResultStringForQuery.Add(StrTemplate("MainRegister.%1ClosingBalance < 0", Resource));
	EndDo;

	Return StrConcat(ResultStringForQuery, Separator);

EndFunction

// Reorders the Dimensions and Resources arrays of the register data in place
// according to the cluster index column order (TOP 0 query to the main register table).
//
// 	Ru: Переупорядочивает массивы Dimensions и Resources данных регистра по месту
// согласно порядку колонок кластерного индекса (запрос TOP 0 к основной таблице регистра).
//
// Parameters:
//  RecordsMetadata - Structure - Metadata of the accumulation register, including dimensions and resources.
//                                The Dimensions and Resources arrays are replaced in place.
//                                Ru: Метаданные регистра накопления с измерениями и ресурсами.
//                                Массивы Dimensions и Resources заменяются по месту.
//@skip-check query-in-loop
Procedure SortMetadataByClusterIndex(RecordsMetadata)

	Query = New Query;
	Query.Text =
	"SELECT TOP 0
	|	*
	|FROM
	|	&AccumulationRegister AS MainRegister";

	Query.Text = StrReplace(Query.Text, "&AccumulationRegister", RecordsMetadata.FullName);

	QueryColumns = Query.Execute().Columns;

	OrderedDimensions = New Array;
	OrderedResources = New Array;

	For Each Column In QueryColumns Do

		If RecordsMetadata.Dimensions.Find(Column.Name) <> Undefined Then
			OrderedDimensions.Add(Column.Name);
		ElsIf RecordsMetadata.Resources.Find(Column.Name) <> Undefined Then
			OrderedResources.Add(Column.Name);
		EndIf;

	EndDo;

	RecordsMetadata.Dimensions = OrderedDimensions;
	RecordsMetadata.Resources = OrderedResources;

EndProcedure

#EndRegion

#Region ErrorProcessor

// Processes the collected control errors: builds the refusal message, writes it
// to the event log and cancels the posting.
//
// 	Ru: Обрабатывает собранные ошибки контроля: формирует сообщение об отказе,
// пишет его в журнал регистрации и отменяет проведение.
//
// Parameters:
//  Errors - Array of Structure - Negative balance points found by the control.
//                                Ru: Точки отрицательных остатков, найденные контролем.
//  Object - DocumentObject - The document being posted.
//                            Ru: Проводимый документ.
Procedure ErrorsProcessing(Errors, Object)

	ErrorsCount = Errors.Count();

	If ErrorsCount > 0 Then

		ResultMessage = "";
		StandardProcessing = True;
		BalanceControlOverridable.OnGenerateRefusalText(Errors, Object, ResultMessage, StandardProcessing);

		If StandardProcessing Then

			AllErrorMessage = New Array;
			BasicErrorMessage = StrTemplate(NStr(
				"ru = 'Система контроля отрицательных остатков. Ошибка при работе с %1:';
				|en = 'Balance control system. Error when work with %1:'"), Object);
			AllErrorMessage.Add(BasicErrorMessage);

			Counter = 1;
			EllipsesForMessageWasPrinted = False;

			For Each Error In Errors Do

				If IsMessageShown(Counter, ErrorsCount) Then

					ErrorText = StrTemplate(NStr("ru = '%1) При работе с ресурсом %2, получается отрицательный остаток %3 на дату %4.
												 |Данные строки: [%5].';
												 |en = '%1) When working with resource %2, the negative balance is %3 on date %4.
												 |String data: [%5].'"), Counter, Error.Resource, Error.Result, Error.Date,
						Error.StructureForLogs);
					AllErrorMessage.Add(ErrorText);

				ElsIf Not EllipsesForMessageWasPrinted Then
					AllErrorMessage.Add(MessagesSeparatorString());
					EllipsesForMessageWasPrinted = True;
				EndIf;

				Counter = Counter + 1;

			EndDo;

			ResultMessage = StrConcat(AllErrorMessage, Chars.LF);

		EndIf;

		WriteRefusalToEventLog(Errors, Object);
		PostingError(ResultMessage);

	EndIf;

EndProcedure

// Defines the message display format: the first FirstMessagesNumber() messages are shown,
// then the "....." separator, then the last LastMessagesNumber() messages.
// When the total fits into these two groups, all messages are shown without the separator.
//
// 	Ru: Определяет формат показа сообщений: показываются первые FirstMessagesNumber() сообщений,
// затем разделитель ".....", затем последние LastMessagesNumber() сообщений.
// Если все сообщения умещаются в эти две группы, показываются все без разделителя.
//
// Parameters:
//  Counter - Number - Current message number.
//                     Ru: Номер текущего сообщения.
//  ErrorsCount - Number - Total number of errors.
//                         Ru: Общее число ошибок.
//
// Returns:
//  Boolean - True if the message with this number is shown to the user.
//            Ru: Истина, если сообщение с этим номером показывается пользователю.
Function IsMessageShown(Counter, ErrorsCount)

	Return Counter <= FirstMessagesNumber() Or Counter > ErrorsCount - LastMessagesNumber();

EndFunction

// Raises the error and rolls back the document posting transaction.
//
// 	Ru: Генерирует ошибку и откатывает транзакцию проведения документа.
//
// Parameters:
//  Description - String - The refusal message text.
//                         Ru: Текст сообщения об отказе.
Procedure PostingError(Description)

	Raise Description;

EndProcedure

// A refusal cancels the posting, so such events are rare and do not bloat the log.
// Event log records survive the transaction rollback - the log is the only trace of the refusal.
//
// 	Ru: Отказ отменяет проведение, поэтому такие события редки и журнал не раздувают.
// Записи журнала переживают откат транзакции - журнал остается единственным следом отказа.
//
// Parameters:
//  Errors - Array of Structure - Negative balance points found by the control.
//                                Ru: Точки отрицательных остатков, найденные контролем.
//  Object - DocumentObject - The document being posted.
//                            Ru: Проводимый документ.
Procedure WriteRefusalToEventLog(Errors, Object)

	LogRefusal = True;
	BalanceControlOverridable.OnDefineRefusalLoggingRequired(Object, LogRefusal);
	If Not LogRefusal Then
		Return;
	EndIf;

	CommentParts = New Array;
	For Index = 0 To Min(Errors.UBound(), LoggedPointsCount() - 1) Do
		LoggedError = Errors[Index];
		CommentParts.Add(StrTemplate("%1 = %2 (%3): [%4]",
			LoggedError.Resource, LoggedError.Result, LoggedError.Date, LoggedError.StructureForLogs));
	EndDo;

	If Errors.Count() > LoggedPointsCount() Then
		CommentParts.Add(StrTemplate(NStr("ru = '... и еще точек минуса: %1';
			|en = '... and more negative points: %1'"), Errors.Count() - LoggedPointsCount()));
	EndIf;

	WriteLogEvent(EventLogEventName(), EventLogLevel.Error, Object.Metadata(), Object.Ref,
		StrConcat(CommentParts, Chars.LF));

EndProcedure

#EndRegion

#Region InternalTools

// Transform structure to string of the form "Key1 = Value1, Key2 = Value2".
//
// 	Ru: Преобразует структуру в строку вида "Ключ1 = Значение1, Ключ2 = Значение2".
//
// Parameters:
//  SourceStructure - Structure - The structure to transform.
//                                Ru: Преобразуемая структура.
//
// Returns:
//  String - String presentation of the structure.
//           Ru: Строковое представление структуры.
Function StructureToString(SourceStructure)

	Parts = New Array;

	For Each Element In SourceStructure Do
		Parts.Add(StrTemplate("%1 = %2", Element.Key, Element.Value));
	EndDo;

	Return StrConcat(Parts, ", ");

EndFunction

// Clear additional properties of the document object. (Fix undoposting and writing case)
//
// 	Ru: Очищает дополнительные свойства объекта документа от ключей контроля
// (закрывает кейс "отмена проведения, затем обычная запись").
//
// Parameters:
//  DocumentObject - DocumentObject - The document whose control keys are cleared.
//                                    Ru: Документ, у которого очищаются ключи контроля.
Procedure ClearAdditionalProperties(DocumentObject)

	DocumentObject.AdditionalProperties.Delete(NameDetailWriteMode());
	DocumentObject.AdditionalProperties.Delete(NameRegistersData());
	DocumentObject.AdditionalProperties.Delete(NameOldDate());

EndProcedure

#EndRegion

#Region Constants

// Returns the prefix of the control keys in the object additional properties.
//
// 	Ru: Возвращает префикс ключей контроля в дополнительных свойствах объекта.
//
// Returns:
//  String - The key prefix.
//           Ru: Префикс ключей.
Function Prefix()
	Return "BC_";
EndFunction

// Returns the additional properties key that stores the old document date (from the past version).
//
// 	Ru: Возвращает имя ключа дополнительных свойств со старой датой документа (из прошлой версии).
//
// Returns:
//  String - The key name.
//           Ru: Имя ключа.
Function NameOldDate()
	Return Prefix() + "OldDate";
EndFunction

// Returns the additional properties key that stores the controlled registers data.
//
// 	Ru: Возвращает имя ключа дополнительных свойств с данными контролируемых регистров.
//
// Returns:
//  String - The key name.
//           Ru: Имя ключа.
Function NameRegistersData()
	Return Prefix() + "RegistersData";
EndFunction

// Returns the additional properties key that stores the write mode details.
//
// 	Ru: Возвращает имя ключа дополнительных свойств с деталями режима записи.
//
// Returns:
//  String - The key name.
//           Ru: Имя ключа.
Function NameDetailWriteMode()
	Return Prefix() + "DetailWriteMode";
EndFunction

// Returns the register data structure key that stores the old expense records snapshot.
//
// 	Ru: Возвращает имя ключа структуры данных регистра со снимком старых движений расхода.
//
// Returns:
//  String - The key name.
//           Ru: Имя ключа.
Function NameOldRecordsExpense()
	Return "OldRecords_Expense";
EndFunction

// Returns the register data structure key that stores the old receipt records snapshot.
//
// 	Ru: Возвращает имя ключа структуры данных регистра со снимком старых движений прихода.
//
// Returns:
//  String - The key name.
//           Ru: Имя ключа.
Function NameOldRecordsReceipt()
	Return "OldRecords_Receipt";
EndFunction

// Returns the number of the first error messages shown before the separator.
//
// 	Ru: Возвращает количество первых сообщений об ошибках, выводимых до разделителя.
//
// Returns:
//  Number - The first messages count.
//           Ru: Количество первых сообщений.
Function FirstMessagesNumber()
	Return 3;
EndFunction

// Returns the number of the last error messages shown after the separator.
//
// 	Ru: Возвращает количество последних сообщений об ошибках, выводимых после разделителя.
//
// Returns:
//  Number - The last messages count.
//           Ru: Количество последних сообщений.
Function LastMessagesNumber()
	Return 2;
EndFunction

// Returns the maximum number of negative balance points read by one batch query.
// Any returned row already cancels the posting, so the bound is safe.
//
// 	Ru: Возвращает максимальное число точек минуса, читаемых одним пакетным запросом.
// Любая возвращенная строка уже отменяет проведение, поэтому ограничение безопасно.
//
// Returns:
//  Number - The maximum negative points count.
//           Ru: Максимальное число точек минуса.
Function MaxNegativePointsCount()
	Return 1000;
EndFunction

// Returns a string used as a separator in log messages.
//
// 	Ru: Возвращает строку, используемую в качестве разделителя в сообщениях.
//
// Returns:
//  String - The separator string.
//           Ru: Строка-разделитель.
Function MessagesSeparatorString()
	Return ".....";
EndFunction

// The name is pinned to the default configuration language so the event log
// groups the refusals under one name regardless of the session language.
//
// 	Ru: Имя привязано к основному языку конфигурации, чтобы журнал регистрации
// группировал отказы под одним именем независимо от языка сеанса.
//
// Returns:
//  String - The event log event name.
//           Ru: Имя события журнала регистрации.
Function EventLogEventName()
	Return NStr("ru = 'Контроль остатков.Отказ';
		|en = 'Balance control.Refusal'", Metadata.DefaultLanguage.LanguageCode);
EndFunction

// Returns the maximum number of negative points formatted into the event log comment.
//
// 	Ru: Возвращает максимальное число точек минуса, выводимых в комментарий журнала регистрации.
//
// Returns:
//  Number - The logged points count.
//           Ru: Число точек в комментарии журнала.
Function LoggedPointsCount()
	Return 5;
EndFunction

#EndRegion

#Region Dependencies

// The region is self-contained: the SSL calls are kept as comments so a base with SSL
// can switch back to the library implementations by uncommenting them.
//
// 	Ru: Область самодостаточна: вызовы БСП оставлены комментариями, чтобы база с БСП
// могла вернуться на библиотечные реализации, раскомментировав их.

// Reads a single attribute value of the object from the database by its reference.
// Returns Undefined when the row is not found by the reference.
//
// 	Ru: Читает значение одного реквизита объекта из базы по ссылке.
// Возвращает Неопределено, если строка по ссылке не найдена.
//
// Parameters:
//  Ref - AnyRef - The object whose attribute is read.
//                 Ru: Объект, чей реквизит читается.
//  AttributeName - String - The attribute name.
//                           Ru: Имя реквизита.
//
// Returns:
//  Arbitrary - The attribute value, or Undefined.
//              Ru: Значение реквизита или Неопределено.
Function _ObjectAttributeValue(Ref, AttributeName)

	// SSL: Return Common.ObjectAttributeValue(Ref, AttributeName);

	QueryText =
	"SELECT
	|	SourceTable.AttributeName AS AttributeValue
	|FROM
	|	TableName AS SourceTable
	|WHERE
	|	SourceTable.Ref = &Ref";
	QueryText = StrReplace(QueryText, "AttributeName", AttributeName);
	QueryText = StrReplace(QueryText, "TableName", Ref.Metadata().FullName());

	Query = New Query(QueryText);
	Query.SetParameter("Ref", Ref);

	Selection = Query.Execute().Select();
	If Selection.Next() Then
		Return Selection.AttributeValue;
	EndIf;

	Return Undefined;

EndFunction

// Supplements the destination array with values from the source array.
//
// 	Ru: Дополняет массив-приемник значениями из массива-источника.
//
// Parameters:
//  DestinationArray - Array of Arbitrary - The array that receives values.
//                                          Ru: Массив-приемник.
//  SourceArray - Array of Arbitrary - The array of values to add.
//                                     Ru: Массив-источник.
Procedure _SupplementArray(DestinationArray, SourceArray)

	// SSL: CommonClientServer.SupplementArray(DestinationArray, SourceArray);

	For Each SourceValue In SourceArray Do
		DestinationArray.Add(SourceValue);
	EndDo;

EndProcedure

// Creates an array filled with the values of one collection column.
//
// 	Ru: Создает массив со значениями одной колонки коллекции.
//
// Parameters:
//  SourceTable - ValueTable - The collection whose column is exported.
//                             Ru: Коллекция, чья колонка выгружается.
//  ColumnName - String - The column name.
//                        Ru: Имя колонки.
//  UniqueValuesOnly - Boolean - If True, only unique values are added.
//                               Ru: Истина - добавляются только уникальные значения.
//
// Returns:
//  Array of Arbitrary - The column values.
//                       Ru: Значения колонки.
Function _UnloadColumn(SourceTable, ColumnName, UniqueValuesOnly)

	// SSL: Return Common.UnloadColumn(SourceTable, ColumnName, UniqueValuesOnly);

	ArrayOfValues = New Array;
	UniqueValues = New Map;

	For Each CollectionRow In SourceTable Do
		ColumnValue = CollectionRow[ColumnName];
		If UniqueValuesOnly And UniqueValues[ColumnValue] <> Undefined Then
			Continue;
		EndIf;
		ArrayOfValues.Add(ColumnValue);
		UniqueValues.Insert(ColumnValue, True);
	EndDo;

	Return ArrayOfValues;
EndFunction

// Substitutes parameter values for their names in the string pattern.
// Parameters in the string are enclosed in square brackets.
//
// 	Ru: Подставляет значения параметров вместо их имен в строке-шаблоне.
// Параметры в строке заключены в квадратные скобки.
//
// Parameters:
//  Template - String - The string to insert values into.
//                      Ru: Строка-шаблон для подстановки.
//  Parameters - Structure - Values to insert; key = parameter name, value = inserted value.
//                           Ru: Значения для подстановки: ключ - имя параметра, значение - подставляемое.
//
// Returns:
//  String - The string with inserted values.
//           Ru: Строка с подставленными значениями.
Function _InsertParametersIntoString(Template, Parameters)

	// SSL: Return StringFunctionsClientServer.InsertParametersIntoString(Template, Parameters);

	Result = Template;
	For Each Parameter In Parameters Do
		Result = StrReplace(Result, "[" + Parameter.Key + "]", Parameter.Value);
	EndDo;
	Return Result;

EndFunction

#EndRegion

#EndRegion