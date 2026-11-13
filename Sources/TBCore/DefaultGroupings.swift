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
        func add(_ section: String, _ code: String, _ name: String, _ type: AccountType?, id: String? = nil) {
            out.append(Grouping(id: id ?? code, code: code, name: name, section: section, type: type))
        }
        /// A subgroup of the grouping just added. It reports under that grouping's code.
        func sub(_ name: String, id: String) {
            guard let parent = out.last(where: { $0.parent == nil }) else { return }
            out.append(Grouping(id: id, code: "", name: name, section: parent.section, parent: parent.id))
        }

        add(section8825, "802", "GROSS RENTS", .revenue)
        add(section8825, "803", "ADVERTISING", .expense)
        add(section8825, "804", "AUTO AND TRAVEL", .expense)
        add(section8825, "805", "CLEANING AND MAINTENANCE", .expense)
        add(section8825, "806", "COMMISSIONS", .expense)
        add(section8825, "807", "INSURANCE", .expense)
        add(section8825, "808", "LEGAL AND PROF FEE", .expense)
        add(section8825, "809", "INTEREST", .expense)
        add(section8825, "810", "REPAIRS", .expense)
        add(section8825, "811", "TAXES", .expense)
        add(section8825, "812", "UTILITIES", .expense)
        add(section8825, "813", "WAGES", .expense)
        add(section8825, "814", "DEPRECIATION", .expense)
        add(section8825, "815", "OTHER", .expense)
        sub("AMORTIZATION", id: "815-AMORT")
        sub("OFFICE EXPENSE", id: "815-OFFICE")
        sub("MANAGEMENT FEES", id: "815-MGMT")
        sub("LAWN CARE", id: "815-LAWN")
        sub("MISCELLANEOUS", id: "815-MISC")
        sub("GUARANTEED PAYMENTS", id: "815-GP")

        add(sectionK, "K01", "ORDINARY INCOME", .revenue)
        add(sectionK, "K02", "RENTAL INCOME", .revenue)
        add(sectionK, "K03", "OTHER RENTAL", .revenue)
        add(sectionK, "K04", "GUARANTEED PAYMENT INCOME", .revenue)
        add(sectionK, "K05", "INTEREST INCOME", .revenue)
        add(sectionK, "K06", "DIVIDENDS", .revenue)
        add(sectionK, "K07", "ROYALTY INCOME", .revenue)
        add(sectionK, "K08", "STCG", .revenue)
        add(sectionK, "K09", "LTCG", .revenue)
        add(sectionK, "K10", "1231 GAIN", .revenue)
        add(sectionK, "K11", "OTHER INCOME", .revenue)
        add(sectionK, "K12", "179 DEDUCTION", .expense)
        add(sectionK, "K13A", "CHARITABLE CONTRIBUTIONS", .expense)
        add(sectionK, "K13W", "OTHER DEDUCTIONS", .expense)
        add(sectionK, "K13V", "743(B) DEDUCTIONS", .expense)
        add(sectionK, "K18A", "TAX - EXEMPT INTEREST", .revenue)
        add(sectionK, "K18B", "NON - TAXABLE INCOME", .revenue)
        add(sectionK, "K18C", "NONDEDUCTIBLE EXPENSES", .expense)

        add(sectionPage1, "1A", "GROSS RECEIPTS OR SALES", .revenue)
        add(sectionPage1, "1B", "RETURNS AND ALLOWANCES", .revenue)
        add(sectionPage1, "2", "COST OF GOODS SOLD", .expense)
        add(sectionPage1, "7", "OTHER INCOME", .revenue)
        add(sectionPage1, "9", "WAGES", .expense)
        add(sectionPage1, "10", "GUARANTEED PAYMENTS", .expense)
        add(sectionPage1, "11", "REPAIRS AND MAINTENANCE", .expense)
        add(sectionPage1, "12", "BAD DEBTS", .expense)
        add(sectionPage1, "13", "RENT", .expense)
        add(sectionPage1, "14", "TAXES AND LICENSES", .expense)
        add(sectionPage1, "15", "INTEREST", .expense)
        add(sectionPage1, "16", "DEPRECIATION", .expense)
        add(sectionPage1, "17", "DEPLETION", .expense)
        add(sectionPage1, "18", "RETIREMENT PLANS", .expense)
        add(sectionPage1, "19", "EMPLOYEE BENEFIT PROGRAMS", .expense)
        add(sectionPage1, "20", "OTHER DEDUCTIONS", .expense)

        add(sectionL, "L01", "CASH", .asset)
        add(sectionL, "L02", "A/R", .asset)
        add(sectionL, "L03", "INVENTORY", .asset)
        add(sectionL, "L04", "US GOV. OBLIGATIONS", .asset)
        add(sectionL, "L06", "OTHER CURRENT ASSETS", .asset)
        add(sectionL, "L07", "LOANS TO PARTNERS", .asset)
        add(sectionL, "L08", "OTHER INVESTMENTS", .asset)
        add(sectionL, "L09A", "BUILDINGS AND DEPRE. ASSETS", .asset)
        add(sectionL, "L09B", "ACCUM. DEPRE.", .asset)
        add(sectionL, "L11", "LAND", .asset)
        add(sectionL, "L12A", "INTANGIBLE ASSETS", .asset)
        add(sectionL, "L12B", "ACCUM. AMORT.", .asset)
        add(sectionL, "L13", "OTHER ASSETS", .asset)
        add(sectionL, "L15", "A/P", .liability)
        add(sectionL, "L16", "SHORT TERM NOTES", .liability)
        add(sectionL, "L17", "OTHER CURRENT LIABILITIES", .liability)
        add(sectionL, "L19A", "PARTNER LOANS", .liability)
        add(sectionL, "L19B", "LT MORTGAGES OR NOTES", .liability)
        add(sectionL, "L20", "OTHER LIABILITIES", .liability)
        add(sectionL, "L21", "PARTNER CAPITAL", .equity)

        add(sectionOther, "MEM", "MEMO ACCOUNT", nil)
        // Kept the way every list is kept: by code within each section, subgroups by name.
        return Engagement.tidiedGroupings(out)
    }()
}
