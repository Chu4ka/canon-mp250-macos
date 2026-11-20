#!/usr/bin/env python3
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor


ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
PACKAGE = f"Canon-MP250-Driver-{VERSION}-macOS-arm64"
OUT = ROOT / "docs" / "Canon-MP250-Driver-Инструкция.docx"
NAVY = "17365D"
BLUE = "2F75B5"
PALE = "EAF2F8"
LIGHT = "F3F6F9"
GREEN = "E2F0D9"
RED = "FCE4D6"


def shade(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = tc_pr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        tc_pr.append(shd)
    shd.set(qn("w:fill"), fill)


def set_cell_margins(cell, top=90, start=110, bottom=90, end=110):
    tc = cell._tc
    tc_pr = tc.get_or_add_tcPr()
    tc_mar = tc_pr.first_child_found_in("w:tcMar")
    if tc_mar is None:
        tc_mar = OxmlElement("w:tcMar")
        tc_pr.append(tc_mar)
    for margin, value in (("top", top), ("start", start), ("bottom", bottom), ("end", end)):
        node = tc_mar.find(qn(f"w:{margin}"))
        if node is None:
            node = OxmlElement(f"w:{margin}")
            tc_mar.append(node)
        node.set(qn("w:w"), str(value))
        node.set(qn("w:type"), "dxa")


def add_field(paragraph, instruction):
    run = paragraph.add_run()
    begin = OxmlElement("w:fldChar")
    begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = instruction
    separate = OxmlElement("w:fldChar")
    separate.set(qn("w:fldCharType"), "separate")
    end = OxmlElement("w:fldChar")
    end.set(qn("w:fldCharType"), "end")
    run._r.extend([begin, instr, separate, end])


def add_code(doc, lines):
    table = doc.add_table(rows=1, cols=1)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    cell = table.cell(0, 0)
    cell.width = Inches(6.65)
    shade(cell, LIGHT)
    set_cell_margins(cell, 110, 150, 110, 150)
    p = cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(0)
    for index, line in enumerate(lines):
        if index:
            p.add_run().add_break()
        run = p.add_run(line)
        run.font.name = "Menlo"
        run.font.size = Pt(9)
        run.font.color.rgb = RGBColor(35, 35, 35)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)


def add_note(doc, title, text, fill=PALE):
    table = doc.add_table(rows=1, cols=1)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    cell = table.cell(0, 0)
    shade(cell, fill)
    set_cell_margins(cell, 105, 150, 105, 150)
    p = cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(0)
    r = p.add_run(title + "  ")
    r.bold = True
    r.font.color.rgb = RGBColor.from_string(NAVY)
    p.add_run(text)


def add_step(doc, number, title, body):
    table = doc.add_table(rows=1, cols=2)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    number_cell, text_cell = table.rows[0].cells
    table.columns[0].width = Inches(0.52)
    table.columns[1].width = Inches(6.1)
    number_cell.width = Inches(0.52)
    text_cell.width = Inches(6.1)
    shade(number_cell, BLUE)
    number_cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    set_cell_margins(number_cell, 90, 60, 90, 60)
    p = number_cell.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(str(number))
    r.bold = True
    r.font.color.rgb = RGBColor(255, 255, 255)
    r.font.size = Pt(13)
    set_cell_margins(text_cell, 70, 140, 70, 80)
    p = text_cell.paragraphs[0]
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run(title)
    r.bold = True
    r.font.color.rgb = RGBColor.from_string(NAVY)
    p = text_cell.add_paragraph(body)
    p.paragraph_format.space_after = Pt(0)
    doc.add_paragraph().paragraph_format.space_after = Pt(0)


def bullet(doc, text):
    p = doc.add_paragraph(text, style="List Bullet")
    p.paragraph_format.space_after = Pt(3)
    return p


def heading(doc, text, level=1):
    return doc.add_heading(text, level=level)


doc = Document()
section = doc.sections[0]
section.top_margin = Inches(0.68)
section.bottom_margin = Inches(0.62)
section.left_margin = Inches(0.8)
section.right_margin = Inches(0.8)

styles = doc.styles
styles["Normal"].font.name = "Aptos"
styles["Normal"].font.size = Pt(10.5)
styles["Normal"].font.color.rgb = RGBColor(43, 43, 43)
styles["Normal"].paragraph_format.space_after = Pt(6)
styles["Normal"].paragraph_format.line_spacing = 1.08
for style_name, size, color in (("Title", 28, "000000"), ("Heading 1", 19, NAVY), ("Heading 2", 13, BLUE)):
    style = styles[style_name]
    style.font.name = "Aptos Display"
    style.font.size = Pt(size)
    style.font.color.rgb = RGBColor.from_string(color)
    style.font.bold = True
    style.paragraph_format.keep_with_next = True
    style.paragraph_format.space_before = Pt(8)
    style.paragraph_format.space_after = Pt(5)

title_properties = styles["Title"].element.get_or_add_pPr()
title_border = title_properties.find(qn("w:pBdr"))
if title_border is not None:
    title_properties.remove(title_border)

for sec in doc.sections:
    footer = sec.footer.paragraphs[0]
    footer.alignment = WD_ALIGN_PARAGRAPH.CENTER
    footer_run = footer.add_run(f"Canon MP250 Driver {VERSION}   •   ")
    footer_run.font.size = Pt(8)
    footer_run.font.color.rgb = RGBColor(110, 110, 110)
    add_field(footer, "PAGE")

# Cover
p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(34)
p.paragraph_format.space_after = Pt(18)
r = p.add_run("CANON PIXMA MP250")
r.bold = True
r.font.name = "Aptos Display"
r.font.size = Pt(13)
r.font.color.rgb = RGBColor.from_string(BLUE)

p = doc.add_paragraph(style="Title")
p.paragraph_format.space_after = Pt(8)
p.add_run("Драйвер для macOS")
p = doc.add_paragraph()
p.paragraph_format.space_after = Pt(24)
r = p.add_run("Установка, печать и диагностика на Apple Silicon")
r.font.size = Pt(16)
r.font.color.rgb = RGBColor.from_string(NAVY)

table = doc.add_table(rows=3, cols=2)
table.alignment = WD_TABLE_ALIGNMENT.CENTER
table.autofit = False
data = [
    ("Версия", VERSION),
    ("Система", "macOS 27 и новее · Apple Silicon arm64"),
    ("Архитектура", "PAPPL / IPP · Gutenprint · libusb"),
]
for row, (left, right) in zip(table.rows, data):
    row.cells[0].width = Inches(1.35)
    row.cells[1].width = Inches(5.15)
    shade(row.cells[0], NAVY)
    shade(row.cells[1], LIGHT)
    for cell in row.cells:
        set_cell_margins(cell, 110, 140, 110, 140)
    a = row.cells[0].paragraphs[0]
    a.paragraph_format.space_after = Pt(0)
    rr = a.add_run(left)
    rr.bold = True
    rr.font.color.rgb = RGBColor(255, 255, 255)
    b = row.cells[1].paragraphs[0]
    b.paragraph_format.space_after = Pt(0)
    b.add_run(right)

doc.add_paragraph().paragraph_format.space_after = Pt(8)
add_note(doc, "Первая печать", "Когда появится очередь Canon_MP250, выберите её в стандартном диалоге печати. Печать на физическом MP250 для этой версии ещё предстоит проверить.", GREEN)

p = doc.add_paragraph()
p.paragraph_format.space_before = Pt(46)
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run("Готовый автономный пакет · Интернет и Homebrew не требуются")
r.italic = True
r.font.color.rgb = RGBColor(95, 95, 95)

doc.add_page_break()

# Install
heading(doc, "Быстрый старт")
p = doc.add_paragraph("В комплекте находятся уже собранные ARM64-компоненты и данные Gutenprint. Нужны только принтер, USB-кабель и пароль администратора Mac.")
p.paragraph_format.space_after = Pt(10)

add_step(doc, 1, "Подключите принтер", "Включите Canon PIXMA MP250 и подключите его напрямую к Mac по USB. На время первой проверки лучше не использовать USB-хаб.")
add_step(doc, 2, "Распакуйте ZIP", f"Дважды щёлкните ZIP-файл. Появится папка {PACKAGE}.")
add_step(doc, 3, "Откройте Terminal", "В Finder выберите «Программы → Утилиты → Терминал». Если папка лежит в Downloads, выполните команды ниже.")
add_code(doc, [
    f"cd ~/Downloads/{PACKAGE}",
    "sudo ./install.sh",
])
add_step(doc, 4, "Введите пароль", "Наберите пароль администратора и нажмите Return. При вводе символы пароля не отображаются.")
add_step(doc, 5, "Дождитесь готовности", "Установщик запустит службу и проверит ответ IPP. После подключения принтера очередь Canon_MP250 может появиться в течение 30 секунд.")

add_note(doc, "Имя очереди", "Если Canon_MP250 уже используется другим драйвером, установщик сохранит эту очередь. Для автоматического добавления новой очереди имя должно быть свободно.", GREEN)

heading(doc, "Если ZIP находится не в Downloads", level=2)
doc.add_paragraph("Введите cd и пробел. Перетащите распакованную папку из Finder в Terminal и нажмите Return. Затем запустите установщик.")
add_code(doc, ["sudo ./install.sh"])

doc.add_page_break()

# Printing
heading(doc, "Печать из Microsoft Word")
add_step(doc, 1, "Откройте документ", "Откройте DOC или DOCX обычным способом в Microsoft Word.")
add_step(doc, 2, "Откройте окно печати", "Нажмите ⌘P или выберите «Файл → Печать».")
add_step(doc, 3, "Выберите принтер", "Выберите Canon_MP250 и задайте страницы, количество копий и цветовой режим.")
add_step(doc, 4, "Отправьте задание", "Нажмите «Печать».")

add_note(doc, "Проверка на принтере", "Напечатайте две разные страницы в цвете. Повторите в оттенках серого с двумя копиями и проверьте страницы каждой копии. Переподключите USB, подождите до 30 секунд и снова напечатайте документ.", PALE)

heading(doc, "Печать из Terminal", level=2)
doc.add_paragraph("Команда mp250-print отправляет PDF в очередь печати. Для DOC/DOCX она использует установленный Microsoft Word для экспорта в PDF.")
add_code(doc, [
    'mp250-print "/полный/путь/к/документу.docx"',
    'mp250-print "/полный/путь/к/документу.pdf"',
])
doc.add_paragraph("При первом использовании DOCX macOS может запросить разрешение Terminal управлять Microsoft Word.")

heading(doc, "Другие приложения", level=2)
doc.add_paragraph("В «Просмотре» и других приложениях откройте «Файл → Печать» и выберите Canon_MP250.")

doc.add_page_break()

# Diagnostics
heading(doc, "Проверка и диагностика")
heading(doc, "Проверить очередь macOS", level=2)
add_code(doc, ["lpstat -p Canon_MP250", "lpstat -v Canon_MP250"])
doc.add_paragraph("Вторая команда показывает адрес очереди. Очередь этого проекта использует локальный IPP на порту 8000 и ресурс Canon_MP250_series_%28USB%29.")

heading(doc, "Проверить USB", level=2)
add_code(doc, ["/usr/local/bin/mp250-diag", "/usr/local/bin/mp250-diag --open"])
doc.add_paragraph("Утилита ищет устройство с VID:PID 04a9:173a. Ключ --open открывает USB-интерфейс и запрашивает IEEE-1284 Device ID.")

heading(doc, "Открыть интерфейс службы", level=2)
doc.add_paragraph("Введите 127.0.0.1:8000 в адресной строке браузера. Веб-интерфейс PAPPL показывает очередь и задания на этом Mac. Журналы доступны через Terminal.")

heading(doc, "Посмотреть журналы", level=2)
add_code(doc, [
    "sudo tail -n 100 /usr/local/var/log/canon-mp250-app.log",
    "sudo tail -n 100 /usr/local/var/log/canon-mp250-launchd.log",
    "sudo tail -n 100 /usr/local/var/log/canon-mp250-autoadd.log",
])

table = doc.add_table(rows=1, cols=2)
table.alignment = WD_TABLE_ALIGNMENT.CENTER
table.style = "Table Grid"
table.rows[0].cells[0].text = "Компонент"
table.rows[0].cells[1].text = "Что фиксируется"
for cell in table.rows[0].cells:
    shade(cell, NAVY)
    for run in cell.paragraphs[0].runs:
        run.bold = True
        run.font.color.rgb = RGBColor(255, 255, 255)
for left, right in [
    ("canon-mp250-app.log", "события и ошибки службы печати"),
    ("canon-mp250-launchd.log", "вывод основной службы, в том числе ошибки запуска"),
    ("canon-mp250-autoadd.log", "обнаружение устройства и добавление очереди"),
]:
    cells = table.add_row().cells
    cells[0].text = left
    cells[1].text = right
    for cell in cells:
        set_cell_margins(cell)

doc.add_page_break()

# Troubleshooting and technical notes
heading(doc, "Решение проблем")
heading(doc, "Очередь Canon_MP250 не появилась", level=2)
bullet(doc, "Убедитесь, что принтер включён и USB-кабель подключён. Подождите 30 секунд.")
bullet(doc, "Проверьте USB командой /usr/local/bin/mp250-diag --open.")
bullet(doc, "Запустите автоматическое добавление очереди.")
add_code(doc, ["sudo /usr/local/libexec/canon-mp250-autoadd"])

heading(doc, "Word отправляет задание, но печати нет", level=2)
bullet(doc, "Проверьте имя и адрес очереди командами с предыдущей страницы.")
bullet(doc, "Попробуйте напечатать PDF из приложения «Просмотр».")
bullet(doc, "Проверьте задание в веб-интерфейсе службы и посмотрите журналы.")

heading(doc, "Обновление и переустановка", level=2)
doc.add_paragraph(f"Для обновления с 0.2.0 на {VERSION} выполните sudo ./install.sh из распакованной папки нового ZIP. Эту команду можно повторить для переустановки.")

heading(doc, "Удаление", level=2)
add_code(doc, [
    f"cd ~/Downloads/{PACKAGE}",
    "sudo ./uninstall.sh",
])
doc.add_paragraph("Удаляются службы, очередь этого проекта, бинарники, данные Gutenprint и состояние печати. Журналы и одноимённая очередь другого драйвера сохраняются.")

heading(doc, "Что находится внутри", level=2)
doc.add_paragraph("PAPPL принимает задания по IPP. Gutenprint формирует поток Canon PIXMA MP250, а libusb передаёт его принтеру по USB.")

add_note(doc, "Ограничения прототипа", "Проект поддерживает печать. Сканирование вне его возможностей. Бинарники собраны без подписи Developer ID.", RED)

doc.core_properties.title = "Canon PIXMA MP250 Driver — инструкция"
doc.core_properties.subject = "Установка и использование Printer Application для macOS"
doc.core_properties.author = "Canon MP250 Driver Project"
doc.core_properties.keywords = "Canon MP250, macOS, PAPPL, IPP, Gutenprint, libusb"

OUT.parent.mkdir(parents=True, exist_ok=True)
doc.save(OUT)
print(OUT)
