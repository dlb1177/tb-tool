import Foundation

/// The built-in grouping list (Form 1065: Form 8825, Schedule K, page 1, Schedule L, plus a memo
/// bucket). Each file carries its own copy, editable in the app, and the list new files start
/// from can be changed in the app's settings. Every code is used once: the "other" lines of
/// Form 8825 line 15 are subgroups of one grouping.
public enum DefaultGroupings {
    public static let section8825 = "8825 Accounts"
    public static let sectionK = "Sch. K Accounts"
    public static let sectionPage1 = "Page 1 Accounts"
    public static let sectionL = "Sch. L Accounts"
    public static let sectionOther = "Other Accounts"

    public static let list: [Grouping] = {
        var out: [Grouping] = []
        func add(_ section: String, _ code: String, _ name: String, id: String? = nil) {
            out.append(Grouping(id: id ?? code, code: code, name: name, section: section))
        }
        /// A subgroup of the grouping just added. It reports under that grouping's code.
        func sub(_ name: String, id: String) {
            guard let parent = out.last(where: { $0.parent == nil }) else { return }
            out.append(Grouping(id: id, code: "", name: name, section: parent.section, parent: parent.id))
        }

        add(section8825, "802", "GROSS RENTS")
        add(section8825, "803", "ADVERTISING")
        add(section8825, "804", "AUTO AND TRAVEL")
        add(section8825, "805", "CLEANING AND MAINTENANCE")
        add(section8825, "806", "COMMISSIONS")
        add(section8825, "807", "INSURANCE")
        add(section8825, "808", "LEGAL AND PROF FEE")
        add(section8825, "809", "INTEREST")
        add(section8825, "810", "REPAIRS")
        add(section8825, "811", "TAXES")
        add(section8825, "812", "UTILITIES")
        add(section8825, "813", "WAGES")
        add(section8825, "814", "DEPRECIATION")
        add(section8825, "815", "OTHER")
        sub("AMORTIZATION", id: "815-AMORT")
        sub("OFFICE EXPENSE", id: "815-OFFICE")
        sub("MANAGEMENT FEES", id: "815-MGMT")
        sub("LAWN CARE", id: "815-LAWN")
        sub("MISCELLANEOUS", id: "815-MISC")
        sub("GUARANTEED PAYMENTS", id: "815-GP")

        add(sectionK, "K01", "ORDINARY INCOME")
        add(sectionK, "K02", "RENTAL INCOME")
        add(sectionK, "K03", "OTHER RENTAL")
        add(sectionK, "K04", "GUARANTEED PAYMENT INCOME")
        add(sectionK, "K05", "INTEREST INCOME")
        add(sectionK, "K06", "DIVIDENDS")
        add(sectionK, "K07", "ROYALTY INCOME")
        add(sectionK, "K08", "STCG")
        add(sectionK, "K09", "LTCG")
        add(sectionK, "K10", "1231 GAIN")
        add(sectionK, "K11", "OTHER INCOME")
        add(sectionK, "K12", "179 DEDUCTION")
        add(sectionK, "K13A", "CHARITABLE CONTRIBUTIONS")
        add(sectionK, "K13W", "OTHER DEDUCTIONS")
        add(sectionK, "K13V", "743(B) DEDUCTIONS")
        add(sectionK, "K18A", "TAX - EXEMPT INTEREST")
        add(sectionK, "K18B", "NON - TAXABLE INCOME")
        add(sectionK, "K18C", "NONDEDUCTIBLE EXPENSES")

        add(sectionPage1, "1A", "GROSS RECEIPTS OR SALES")
        add(sectionPage1, "1B", "RETURNS AND ALLOWANCES")
        add(sectionPage1, "2", "COST OF GOODS SOLD")
        add(sectionPage1, "7", "OTHER INCOME")
        add(sectionPage1, "9", "WAGES")
        add(sectionPage1, "10", "GUARANTEED PAYMENTS")
        add(sectionPage1, "11", "REPAIRS AND MAINTENANCE")
        add(sectionPage1, "12", "BAD DEBTS")
        add(sectionPage1, "13", "RENT")
        add(sectionPage1, "14", "TAXES AND LICENSES")
        add(sectionPage1, "15", "INTEREST")
        add(sectionPage1, "16", "DEPRECIATION")
        add(sectionPage1, "17", "DEPLETION")
        add(sectionPage1, "18", "RETIREMENT PLANS")
        add(sectionPage1, "19", "EMPLOYEE BENEFIT PROGRAMS")
        add(sectionPage1, "20", "OTHER DEDUCTIONS")

        add(sectionL, "L01", "CASH")
        add(sectionL, "L02", "A/R")
        add(sectionL, "L03", "INVENTORY")
        add(sectionL, "L04", "US GOV. OBLIGATIONS")
        add(sectionL, "L06", "OTHER CURRENT ASSETS")
        add(sectionL, "L07", "LOANS TO PARTNERS")
        add(sectionL, "L08", "OTHER INVESTMENTS")
        add(sectionL, "L09A", "BUILDINGS AND DEPRE. ASSETS")
        add(sectionL, "L09B", "ACCUM. DEPRE.")
        add(sectionL, "L11", "LAND")
        add(sectionL, "L12A", "INTANGIBLE ASSETS")
        add(sectionL, "L12B", "ACCUM. AMORT.")
        add(sectionL, "L13", "OTHER ASSETS")
        add(sectionL, "L15", "A/P")
        add(sectionL, "L16", "SHORT TERM NOTES")
        add(sectionL, "L17", "OTHER CURRENT LIABILITIES")
        add(sectionL, "L19A", "PARTNER LOANS")
        add(sectionL, "L19B", "LT MORTGAGES OR NOTES")
        add(sectionL, "L20", "OTHER LIABILITIES")
        add(sectionL, "L21", "PARTNER CAPITAL")

        add(sectionOther, "MEM", "MEMO ACCOUNT")
        // Kept the way every list is kept: by code within each section, subgroups by name.
        return Engagement.tidiedGroupings(out)
    }()
}
