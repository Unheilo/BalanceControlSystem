#Region Internal

// Called before taking the snapshot of old register records. Allows to skip the balance control
// for a particular document write: exclusions by organization, operation, exchange load specifics.
// Skipping the snapshot here automatically skips the check on posting as well.
//
// Ru: Вызывается перед снятием снимка старых движений. Позволяет пропустить контроль остатков
// для конкретной записи документа: исключения по организации, операции, особенностям обменов.
// Пропуск снимка здесь автоматически пропускает и проверку при проведении.
//
// Parameters:
//  Object - DocumentObject - The document being written. Read-only.
//                            Ru: Записываемый документ. Только для чтения.
//  ControlRequired - Boolean - True by default. Set to False to skip the control for this write.
//                              Ru: По умолчанию Истина. Установите Ложь, чтобы пропустить
//                              контроль для этой записи.
//
// Example:
//	If TypeOf(Object) = Type("DocumentObject.GoodsWriteOff") Then
//		ControlRequired = False;
//	EndIf;
//
Procedure OnDefineControlRequired(Object, ControlRequired) Export



EndProcedure

// Called once per document write while register metadata is collected for the snapshot.
// Allows to control only some of the register resources: remove a name from the Resources array
// and the resource is not checked for negative balance (e.g. control Quantity but not Amount).
// Unknown names are discarded after the call; an empty array is a configuration error and raises
// an exception.
//
// Ru: Вызывается один раз на запись документа при сборе метаданных регистра для снимка.
// Позволяет контролировать только часть ресурсов регистра: удалите имя из массива Ресурсы -
// и ресурс не проверяется на отрицательный остаток (например, контроль количества без суммы).
// Неизвестные имена отбрасываются после вызова; пустой массив - ошибка конфигурирования,
// вызывается исключение.
//
// Parameters:
//  Object - DocumentObject - The document being written. Read-only.
//                            Ru: Записываемый документ. Только для чтения.
//  RegisterMetadata - MetadataObject - The accumulation register under control.
//                                      Ru: Контролируемый регистр накопления.
//  Resources - Array of String - Names of the controlled resources. Remove items to exclude
//                                resources from the control.
//                                Ru: Имена контролируемых ресурсов. Удаляйте элементы,
//                                чтобы исключить ресурсы из контроля.
//
// Example:
//	If RegisterMetadata.Name = "InventoryInWarehouses" Then
//		ResourceIndex = Resources.Find("Amount");
//		If ResourceIndex <> Undefined Then
//			Resources.Delete(ResourceIndex);
//		EndIf;
//	EndIf;
//
Procedure OnDefineControlledResources(Object, RegisterMetadata, Resources) Export



EndProcedure

// Called when the control found negative balances, before the standard refusal message is built.
// Allows to replace the text shown to the user and thrown as the posting exception.
//
// Ru: Вызывается, когда контроль нашел отрицательные остатки, до сборки стандартного сообщения.
// Позволяет заменить текст, который увидит пользователь и который уйдет в исключение проведения.
//
// Parameters:
//  Errors - Array of Structure - Negative balance points:
//                                Ru: Точки отрицательных остатков:
//    * Resource - String - Resource name.
//                          Ru: Имя ресурса.
//    * Result - Number - Negative balance value.
//                        Ru: Значение отрицательного остатка.
//    * Date - Date - Date of the negative point.
//                    Ru: Дата точки минуса.
//    * StructureForLogs - String - Dimension key presentation.
//                                  Ru: Представление ключа измерений.
//  Object - DocumentObject - The document being posted. Read-only.
//                            Ru: Проводимый документ. Только для чтения.
//  Text - String - Empty by default. The refusal text used when StandardProcessing is False.
//                  Ru: По умолчанию пустая строка. Текст отказа, используемый
//                  при СтандартнаяОбработка = Ложь.
//  StandardProcessing - Boolean - True by default. Set to False to use Text instead of
//                                 the standard message.
//                                 Ru: По умолчанию Истина. Установите Ложь, чтобы использовать
//                                 Текст вместо стандартного сообщения.
//
// Example:
//	FirstError = Errors[0];
//	Text = StrTemplate(NStr("ru = 'Не хватает остатка по ресурсу %1 для проведения %2. Обратитесь на склад.';
//		|en = 'Not enough %1 balance to post %2. Contact the warehouse.'"), FirstError.Resource, Object);
//	StandardProcessing = False;
//
Procedure OnGenerateRefusalText(Errors, Object, Text, StandardProcessing) Export



EndProcedure

// Called on a refusal before writing the event log record. Allows to skip logging
// for particular documents, e.g. a document type known to produce noisy refusals.
//
// Ru: Вызывается при отказе перед записью в журнал регистрации. Позволяет пропустить
// логирование для отдельных документов, например заведомо шумного вида документа.
//
// Parameters:
//  Object - DocumentObject - The document being posted. Read-only.
//                            Ru: Проводимый документ. Только для чтения.
//  LogRefusal - Boolean - True by default. Set to False to skip the event log record.
//                         Ru: По умолчанию Истина. Установите Ложь, чтобы не писать
//                         запись в журнал регистрации.
//
// Example:
//	If TypeOf(Object) = Type("DocumentObject.RetailSalesReport") Then
//		LogRefusal = False;
//	EndIf;
//
Procedure OnDefineRefusalLoggingRequired(Object, LogRefusal) Export



EndProcedure

#EndRegion
