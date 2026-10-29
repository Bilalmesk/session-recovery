#requires -Version 5.1
<#
    StudioTheme.ps1
    Shared theme catalog and palette helpers for the Studio and the restore
    window. Dot-source this file after the localization helpers so theme
    labels can fall back to English when a translation is missing.
#>

$script:StudioThemeCatalog = $null
function Get-StudioThemeCatalog {
    if ($null -ne $script:StudioThemeCatalog) { return $script:StudioThemeCatalog }
    $script:StudioThemeCatalog = [ordered]@{
        'Aurora' = @{
            Key         = 'Aurora'
            Label       = 'Aurora (dark)'
            Description = 'Violet twilight with cool cyan highlights.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(8, 12, 18)
                Sidebar     = [System.Drawing.Color]::FromArgb(11, 16, 24)
                Card        = [System.Drawing.Color]::FromArgb(18, 25, 36)
                CardAlt     = [System.Drawing.Color]::FromArgb(14, 20, 30)
                CardHover   = [System.Drawing.Color]::FromArgb(26, 36, 51)
                Border      = [System.Drawing.Color]::FromArgb(34, 45, 61)
                BorderSoft  = [System.Drawing.Color]::FromArgb(26, 35, 48)
                Text        = [System.Drawing.Color]::FromArgb(238, 244, 252)
                Muted       = [System.Drawing.Color]::FromArgb(130, 145, 165)
                Subtle      = [System.Drawing.Color]::FromArgb(96, 112, 133)
                Accent      = [System.Drawing.Color]::FromArgb(108, 99, 255)
                Accent2     = [System.Drawing.Color]::FromArgb(51, 181, 229)
                AccentSoft  = [System.Drawing.Color]::FromArgb(31, 31, 61)
                AccentHover = [System.Drawing.Color]::FromArgb(124, 117, 255)
                AccentPressed = [System.Drawing.Color]::FromArgb(84, 76, 214)
                Green       = [System.Drawing.Color]::FromArgb(83, 221, 151)
                GreenSoft   = [System.Drawing.Color]::FromArgb(25, 51, 42)
                Amber       = [System.Drawing.Color]::FromArgb(244, 184, 96)
                AmberSoft   = [System.Drawing.Color]::FromArgb(56, 43, 25)
                Red         = [System.Drawing.Color]::FromArgb(255, 107, 129)
                RedSoft     = [System.Drawing.Color]::FromArgb(61, 29, 38)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(11, 10, 26)
                NavSelected = [System.Drawing.Color]::FromArgb(27, 38, 54)
                NavHover    = [System.Drawing.Color]::FromArgb(20, 29, 42)
                Pressed     = [System.Drawing.Color]::FromArgb(22, 30, 43)
                ToggleOff   = [System.Drawing.Color]::FromArgb(45, 55, 70)
                SparkFill   = [System.Drawing.Color]::FromArgb(55, 45, 150)
                ComboSelection = [System.Drawing.Color]::FromArgb(40, 52, 72)
                DisabledFill   = [System.Drawing.Color]::FromArgb(44, 52, 65)
                DisabledText   = [System.Drawing.Color]::FromArgb(131, 143, 160)
                DangerHover    = [System.Drawing.Color]::FromArgb(84, 36, 49)
                DangerPressed  = [System.Drawing.Color]::FromArgb(70, 30, 41)
                DangerOutline  = [System.Drawing.Color]::FromArgb(92, 48, 62)
            }
        }
        'Daylight' = @{
            Key         = 'Daylight'
            Label       = 'Daylight (light)'
            Description = 'Crisp white with a calm blue accent.'
            Dark        = $false
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(244, 247, 252)
                Sidebar     = [System.Drawing.Color]::FromArgb(236, 240, 248)
                Card        = [System.Drawing.Color]::FromArgb(255, 255, 255)
                CardAlt     = [System.Drawing.Color]::FromArgb(246, 249, 253)
                CardHover   = [System.Drawing.Color]::FromArgb(232, 238, 249)
                Border      = [System.Drawing.Color]::FromArgb(205, 215, 230)
                BorderSoft  = [System.Drawing.Color]::FromArgb(221, 228, 239)
                Text        = [System.Drawing.Color]::FromArgb(23, 31, 44)
                Muted       = [System.Drawing.Color]::FromArgb(84, 98, 117)
                Subtle      = [System.Drawing.Color]::FromArgb(121, 134, 152)
                Accent      = [System.Drawing.Color]::FromArgb(92, 80, 240)
                Accent2     = [System.Drawing.Color]::FromArgb(18, 148, 196)
                AccentSoft  = [System.Drawing.Color]::FromArgb(235, 232, 255)
                AccentHover = [System.Drawing.Color]::FromArgb(108, 96, 250)
                AccentPressed = [System.Drawing.Color]::FromArgb(96, 84, 222)
                Green       = [System.Drawing.Color]::FromArgb(18, 131, 75)
                GreenSoft   = [System.Drawing.Color]::FromArgb(220, 243, 230)
                Amber       = [System.Drawing.Color]::FromArgb(155, 104, 10)
                AmberSoft   = [System.Drawing.Color]::FromArgb(251, 240, 216)
                Red         = [System.Drawing.Color]::FromArgb(191, 48, 70)
                RedSoft     = [System.Drawing.Color]::FromArgb(251, 228, 232)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(9, 8, 24)
                NavSelected = [System.Drawing.Color]::FromArgb(225, 233, 245)
                NavHover    = [System.Drawing.Color]::FromArgb(239, 244, 251)
                Pressed     = [System.Drawing.Color]::FromArgb(218, 227, 241)
                ToggleOff   = [System.Drawing.Color]::FromArgb(198, 208, 222)
                SparkFill   = [System.Drawing.Color]::FromArgb(215, 211, 255)
                ComboSelection = [System.Drawing.Color]::FromArgb(225, 233, 245)
                DisabledFill   = [System.Drawing.Color]::FromArgb(233, 238, 245)
                DisabledText   = [System.Drawing.Color]::FromArgb(106, 118, 134)
                DangerHover    = [System.Drawing.Color]::FromArgb(248, 217, 223)
                DangerPressed  = [System.Drawing.Color]::FromArgb(242, 204, 212)
                DangerOutline  = [System.Drawing.Color]::FromArgb(227, 177, 189)
            }
        }
        'Midnight' = @{
            Key         = 'Midnight'
            Label       = 'Midnight (dark)'
            Description = 'Deep navy with electric blue and cyan.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(6, 12, 24)
                Sidebar     = [System.Drawing.Color]::FromArgb(9, 17, 32)
                Card        = [System.Drawing.Color]::FromArgb(14, 25, 45)
                CardAlt     = [System.Drawing.Color]::FromArgb(10, 19, 35)
                CardHover   = [System.Drawing.Color]::FromArgb(21, 37, 64)
                Border      = [System.Drawing.Color]::FromArgb(33, 54, 86)
                BorderSoft  = [System.Drawing.Color]::FromArgb(24, 41, 68)
                Text        = [System.Drawing.Color]::FromArgb(232, 241, 255)
                Muted       = [System.Drawing.Color]::FromArgb(132, 151, 181)
                Subtle      = [System.Drawing.Color]::FromArgb(95, 115, 148)
                Accent      = [System.Drawing.Color]::FromArgb(60, 132, 246)
                Accent2     = [System.Drawing.Color]::FromArgb(32, 207, 236)
                AccentSoft  = [System.Drawing.Color]::FromArgb(20, 41, 76)
                AccentHover = [System.Drawing.Color]::FromArgb(82, 149, 255)
                AccentPressed = [System.Drawing.Color]::FromArgb(36, 109, 219)
                Green       = [System.Drawing.Color]::FromArgb(72, 222, 166)
                GreenSoft   = [System.Drawing.Color]::FromArgb(19, 54, 47)
                Amber       = [System.Drawing.Color]::FromArgb(250, 189, 89)
                AmberSoft   = [System.Drawing.Color]::FromArgb(58, 44, 22)
                Red         = [System.Drawing.Color]::FromArgb(255, 107, 129)
                RedSoft     = [System.Drawing.Color]::FromArgb(64, 29, 41)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(6, 13, 25)
                NavSelected = [System.Drawing.Color]::FromArgb(23, 43, 74)
                NavHover    = [System.Drawing.Color]::FromArgb(15, 29, 53)
                Pressed     = [System.Drawing.Color]::FromArgb(19, 35, 61)
                ToggleOff   = [System.Drawing.Color]::FromArgb(42, 60, 86)
                SparkFill   = [System.Drawing.Color]::FromArgb(24, 58, 123)
                ComboSelection = [System.Drawing.Color]::FromArgb(33, 56, 94)
                DisabledFill   = [System.Drawing.Color]::FromArgb(39, 52, 70)
                DisabledText   = [System.Drawing.Color]::FromArgb(125, 141, 164)
                DangerHover    = [System.Drawing.Color]::FromArgb(86, 36, 50)
                DangerPressed  = [System.Drawing.Color]::FromArgb(72, 30, 42)
                DangerOutline  = [System.Drawing.Color]::FromArgb(94, 48, 63)
            }
        }
        'Forest' = @{
            Key         = 'Forest'
            Label       = 'Forest (dark)'
            Description = 'Mossy charcoal with fresh green light.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(6, 15, 13)
                Sidebar     = [System.Drawing.Color]::FromArgb(9, 22, 19)
                Card        = [System.Drawing.Color]::FromArgb(14, 31, 26)
                CardAlt     = [System.Drawing.Color]::FromArgb(10, 24, 21)
                CardHover   = [System.Drawing.Color]::FromArgb(22, 45, 38)
                Border      = [System.Drawing.Color]::FromArgb(34, 64, 54)
                BorderSoft  = [System.Drawing.Color]::FromArgb(24, 50, 42)
                Text        = [System.Drawing.Color]::FromArgb(231, 246, 238)
                Muted       = [System.Drawing.Color]::FromArgb(128, 154, 143)
                Subtle      = [System.Drawing.Color]::FromArgb(93, 119, 107)
                Accent      = [System.Drawing.Color]::FromArgb(45, 205, 112)
                Accent2     = [System.Drawing.Color]::FromArgb(24, 190, 157)
                AccentSoft  = [System.Drawing.Color]::FromArgb(18, 57, 42)
                AccentHover = [System.Drawing.Color]::FromArgb(63, 220, 132)
                AccentPressed = [System.Drawing.Color]::FromArgb(32, 163, 90)
                Green       = [System.Drawing.Color]::FromArgb(94, 230, 158)
                GreenSoft   = [System.Drawing.Color]::FromArgb(23, 61, 43)
                Amber       = [System.Drawing.Color]::FromArgb(245, 190, 96)
                AmberSoft   = [System.Drawing.Color]::FromArgb(56, 44, 24)
                Red         = [System.Drawing.Color]::FromArgb(255, 115, 125)
                RedSoft     = [System.Drawing.Color]::FromArgb(64, 31, 36)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(4, 20, 11)
                NavSelected = [System.Drawing.Color]::FromArgb(24, 54, 42)
                NavHover    = [System.Drawing.Color]::FromArgb(16, 40, 32)
                Pressed     = [System.Drawing.Color]::FromArgb(20, 46, 36)
                ToggleOff   = [System.Drawing.Color]::FromArgb(44, 68, 57)
                SparkFill   = [System.Drawing.Color]::FromArgb(24, 83, 57)
                ComboSelection = [System.Drawing.Color]::FromArgb(32, 66, 51)
                DisabledFill   = [System.Drawing.Color]::FromArgb(37, 55, 46)
                DisabledText   = [System.Drawing.Color]::FromArgb(123, 143, 131)
                DangerHover    = [System.Drawing.Color]::FromArgb(86, 38, 44)
                DangerPressed  = [System.Drawing.Color]::FromArgb(72, 31, 37)
                DangerOutline  = [System.Drawing.Color]::FromArgb(94, 50, 56)
            }
        }
        'Ember' = @{
            Key         = 'Ember'
            Label       = 'Ember (dark)'
            Description = 'Warm charcoal with amber and coral.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(17, 12, 10)
                Sidebar     = [System.Drawing.Color]::FromArgb(24, 16, 13)
                Card        = [System.Drawing.Color]::FromArgb(33, 23, 19)
                CardAlt     = [System.Drawing.Color]::FromArgb(27, 18, 15)
                CardHover   = [System.Drawing.Color]::FromArgb(48, 33, 26)
                Border      = [System.Drawing.Color]::FromArgb(64, 44, 34)
                BorderSoft  = [System.Drawing.Color]::FromArgb(50, 35, 27)
                Text        = [System.Drawing.Color]::FromArgb(255, 245, 237)
                Muted       = [System.Drawing.Color]::FromArgb(173, 146, 130)
                Subtle      = [System.Drawing.Color]::FromArgb(126, 104, 91)
                Accent      = [System.Drawing.Color]::FromArgb(255, 120, 66)
                Accent2     = [System.Drawing.Color]::FromArgb(255, 186, 79)
                AccentSoft  = [System.Drawing.Color]::FromArgb(65, 34, 23)
                AccentHover = [System.Drawing.Color]::FromArgb(255, 143, 97)
                AccentPressed = [System.Drawing.Color]::FromArgb(218, 91, 41)
                Green       = [System.Drawing.Color]::FromArgb(103, 220, 156)
                GreenSoft   = [System.Drawing.Color]::FromArgb(29, 58, 43)
                Amber       = [System.Drawing.Color]::FromArgb(255, 192, 92)
                AmberSoft   = [System.Drawing.Color]::FromArgb(66, 48, 23)
                Red         = [System.Drawing.Color]::FromArgb(255, 106, 118)
                RedSoft     = [System.Drawing.Color]::FromArgb(69, 29, 35)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(26, 12, 7)
                NavSelected = [System.Drawing.Color]::FromArgb(55, 36, 28)
                NavHover    = [System.Drawing.Color]::FromArgb(34, 24, 19)
                Pressed     = [System.Drawing.Color]::FromArgb(43, 29, 23)
                ToggleOff   = [System.Drawing.Color]::FromArgb(72, 52, 42)
                SparkFill   = [System.Drawing.Color]::FromArgb(92, 45, 26)
                ComboSelection = [System.Drawing.Color]::FromArgb(64, 43, 33)
                DisabledFill   = [System.Drawing.Color]::FromArgb(55, 43, 36)
                DisabledText   = [System.Drawing.Color]::FromArgb(150, 127, 114)
                DangerHover    = [System.Drawing.Color]::FromArgb(90, 39, 47)
                DangerPressed  = [System.Drawing.Color]::FromArgb(75, 31, 39)
                DangerOutline  = [System.Drawing.Color]::FromArgb(99, 52, 61)
            }
        }
        'Neon' = @{
            Key         = 'Neon'
            Label       = 'Neon (dark)'
            Description = 'Inky black with magenta and cyan.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(8, 6, 16)
                Sidebar     = [System.Drawing.Color]::FromArgb(12, 9, 22)
                Card        = [System.Drawing.Color]::FromArgb(20, 15, 35)
                CardAlt     = [System.Drawing.Color]::FromArgb(15, 11, 28)
                CardHover   = [System.Drawing.Color]::FromArgb(32, 23, 53)
                Border      = [System.Drawing.Color]::FromArgb(49, 35, 76)
                BorderSoft  = [System.Drawing.Color]::FromArgb(37, 27, 59)
                Text        = [System.Drawing.Color]::FromArgb(246, 241, 255)
                Muted       = [System.Drawing.Color]::FromArgb(160, 143, 189)
                Subtle      = [System.Drawing.Color]::FromArgb(117, 101, 145)
                Accent      = [System.Drawing.Color]::FromArgb(255, 64, 160)
                Accent2     = [System.Drawing.Color]::FromArgb(38, 231, 255)
                AccentSoft  = [System.Drawing.Color]::FromArgb(56, 20, 48)
                AccentHover = [System.Drawing.Color]::FromArgb(255, 91, 179)
                AccentPressed = [System.Drawing.Color]::FromArgb(214, 36, 124)
                Green       = [System.Drawing.Color]::FromArgb(99, 255, 179)
                GreenSoft   = [System.Drawing.Color]::FromArgb(17, 59, 44)
                Amber       = [System.Drawing.Color]::FromArgb(255, 214, 91)
                AmberSoft   = [System.Drawing.Color]::FromArgb(66, 51, 18)
                Red         = [System.Drawing.Color]::FromArgb(255, 92, 119)
                RedSoft     = [System.Drawing.Color]::FromArgb(68, 23, 38)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(26, 6, 16)
                NavSelected = [System.Drawing.Color]::FromArgb(41, 22, 56)
                NavHover    = [System.Drawing.Color]::FromArgb(24, 17, 42)
                Pressed     = [System.Drawing.Color]::FromArgb(31, 21, 49)
                ToggleOff   = [System.Drawing.Color]::FromArgb(61, 44, 83)
                SparkFill   = [System.Drawing.Color]::FromArgb(79, 21, 74)
                ComboSelection = [System.Drawing.Color]::FromArgb(56, 30, 73)
                DisabledFill   = [System.Drawing.Color]::FromArgb(46, 34, 62)
                DisabledText   = [System.Drawing.Color]::FromArgb(138, 121, 161)
                DangerHover    = [System.Drawing.Color]::FromArgb(90, 32, 55)
                DangerPressed  = [System.Drawing.Color]::FromArgb(75, 25, 46)
                DangerOutline  = [System.Drawing.Color]::FromArgb(98, 42, 67)
            }
        }
        'Sakura' = @{
            Key         = 'Sakura'
            Label       = 'Sakura (light)'
            Description = 'Soft blush with rose and violet.'
            Dark        = $false
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(253, 246, 249)
                Sidebar     = [System.Drawing.Color]::FromArgb(249, 235, 242)
                Card        = [System.Drawing.Color]::FromArgb(255, 255, 255)
                CardAlt     = [System.Drawing.Color]::FromArgb(255, 248, 251)
                CardHover   = [System.Drawing.Color]::FromArgb(250, 234, 242)
                Border      = [System.Drawing.Color]::FromArgb(235, 205, 219)
                BorderSoft  = [System.Drawing.Color]::FromArgb(244, 221, 231)
                Text        = [System.Drawing.Color]::FromArgb(48, 30, 40)
                Muted       = [System.Drawing.Color]::FromArgb(118, 90, 104)
                Subtle      = [System.Drawing.Color]::FromArgb(153, 123, 138)
                Accent      = [System.Drawing.Color]::FromArgb(211, 69, 137)
                Accent2     = [System.Drawing.Color]::FromArgb(138, 89, 244)
                AccentSoft  = [System.Drawing.Color]::FromArgb(252, 229, 240)
                AccentHover = [System.Drawing.Color]::FromArgb(224, 86, 152)
                AccentPressed = [System.Drawing.Color]::FromArgb(177, 47, 109)
                Green       = [System.Drawing.Color]::FromArgb(22, 139, 89)
                GreenSoft   = [System.Drawing.Color]::FromArgb(225, 245, 234)
                Amber       = [System.Drawing.Color]::FromArgb(168, 108, 16)
                AmberSoft   = [System.Drawing.Color]::FromArgb(252, 241, 219)
                Red         = [System.Drawing.Color]::FromArgb(197, 50, 77)
                RedSoft     = [System.Drawing.Color]::FromArgb(252, 228, 233)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(21, 7, 14)
                NavSelected = [System.Drawing.Color]::FromArgb(250, 227, 238)
                NavHover    = [System.Drawing.Color]::FromArgb(253, 240, 246)
                Pressed     = [System.Drawing.Color]::FromArgb(247, 218, 230)
                ToggleOff   = [System.Drawing.Color]::FromArgb(225, 198, 212)
                SparkFill   = [System.Drawing.Color]::FromArgb(247, 203, 224)
                ComboSelection = [System.Drawing.Color]::FromArgb(250, 227, 238)
                DisabledFill   = [System.Drawing.Color]::FromArgb(244, 232, 238)
                DisabledText   = [System.Drawing.Color]::FromArgb(124, 99, 112)
                DangerHover    = [System.Drawing.Color]::FromArgb(248, 216, 224)
                DangerPressed  = [System.Drawing.Color]::FromArgb(242, 203, 213)
                DangerOutline  = [System.Drawing.Color]::FromArgb(227, 176, 189)
            }
        }
        'Paper' = @{
            Key         = 'Paper'
            Label       = 'Paper (light)'
            Description = 'Warm paper with teal ink and amber.'
            Dark        = $false
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(246, 243, 236)
                Sidebar     = [System.Drawing.Color]::FromArgb(239, 235, 226)
                Card        = [System.Drawing.Color]::FromArgb(255, 253, 249)
                CardAlt     = [System.Drawing.Color]::FromArgb(249, 246, 239)
                CardHover   = [System.Drawing.Color]::FromArgb(240, 235, 224)
                Border      = [System.Drawing.Color]::FromArgb(217, 209, 195)
                BorderSoft  = [System.Drawing.Color]::FromArgb(230, 223, 212)
                Text        = [System.Drawing.Color]::FromArgb(45, 42, 36)
                Muted       = [System.Drawing.Color]::FromArgb(106, 99, 87)
                Subtle      = [System.Drawing.Color]::FromArgb(141, 133, 119)
                Accent      = [System.Drawing.Color]::FromArgb(35, 108, 118)
                Accent2     = [System.Drawing.Color]::FromArgb(176, 103, 43)
                AccentSoft  = [System.Drawing.Color]::FromArgb(226, 240, 239)
                AccentHover = [System.Drawing.Color]::FromArgb(51, 130, 141)
                AccentPressed = [System.Drawing.Color]::FromArgb(26, 85, 93)
                Green       = [System.Drawing.Color]::FromArgb(30, 126, 80)
                GreenSoft   = [System.Drawing.Color]::FromArgb(224, 242, 232)
                Amber       = [System.Drawing.Color]::FromArgb(164, 105, 18)
                AmberSoft   = [System.Drawing.Color]::FromArgb(247, 237, 217)
                Red         = [System.Drawing.Color]::FromArgb(188, 53, 68)
                RedSoft     = [System.Drawing.Color]::FromArgb(248, 227, 230)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(254, 254, 254)
                NavSelected = [System.Drawing.Color]::FromArgb(231, 236, 229)
                NavHover    = [System.Drawing.Color]::FromArgb(244, 240, 232)
                Pressed     = [System.Drawing.Color]::FromArgb(225, 231, 223)
                ToggleOff   = [System.Drawing.Color]::FromArgb(205, 198, 184)
                SparkFill   = [System.Drawing.Color]::FromArgb(205, 226, 227)
                ComboSelection = [System.Drawing.Color]::FromArgb(231, 236, 229)
                DisabledFill   = [System.Drawing.Color]::FromArgb(237, 233, 224)
                DisabledText   = [System.Drawing.Color]::FromArgb(114, 106, 93)
                DangerHover    = [System.Drawing.Color]::FromArgb(247, 215, 220)
                DangerPressed  = [System.Drawing.Color]::FromArgb(241, 202, 209)
                DangerOutline  = [System.Drawing.Color]::FromArgb(225, 175, 185)
            }
        }
        'Synthwave' = @{
            Key         = 'Synthwave'
            Label       = 'Synthwave (dark)'
            Description = 'Retro purple night with hot pink sunsets.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(16, 10, 28)
                Sidebar     = [System.Drawing.Color]::FromArgb(21, 13, 36)
                Card        = [System.Drawing.Color]::FromArgb(30, 19, 50)
                CardAlt     = [System.Drawing.Color]::FromArgb(24, 15, 41)
                CardHover   = [System.Drawing.Color]::FromArgb(43, 28, 70)
                Border      = [System.Drawing.Color]::FromArgb(70, 45, 108)
                BorderSoft  = [System.Drawing.Color]::FromArgb(52, 33, 82)
                Text        = [System.Drawing.Color]::FromArgb(245, 238, 255)
                Muted       = [System.Drawing.Color]::FromArgb(165, 148, 196)
                Subtle      = [System.Drawing.Color]::FromArgb(122, 106, 152)
                Accent      = [System.Drawing.Color]::FromArgb(255, 45, 170)
                Accent2     = [System.Drawing.Color]::FromArgb(255, 130, 61)
                AccentSoft  = [System.Drawing.Color]::FromArgb(66, 22, 58)
                AccentHover = [System.Drawing.Color]::FromArgb(255, 78, 190)
                AccentPressed = [System.Drawing.Color]::FromArgb(212, 28, 136)
                Green       = [System.Drawing.Color]::FromArgb(120, 235, 172)
                GreenSoft   = [System.Drawing.Color]::FromArgb(23, 63, 46)
                Amber       = [System.Drawing.Color]::FromArgb(255, 205, 94)
                AmberSoft   = [System.Drawing.Color]::FromArgb(66, 51, 21)
                Red         = [System.Drawing.Color]::FromArgb(255, 96, 122)
                RedSoft     = [System.Drawing.Color]::FromArgb(70, 24, 38)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(26, 4, 17)
                NavSelected = [System.Drawing.Color]::FromArgb(52, 28, 72)
                NavHover    = [System.Drawing.Color]::FromArgb(32, 19, 52)
                Pressed     = [System.Drawing.Color]::FromArgb(42, 23, 58)
                ToggleOff   = [System.Drawing.Color]::FromArgb(74, 56, 96)
                SparkFill   = [System.Drawing.Color]::FromArgb(96, 26, 88)
                ComboSelection = [System.Drawing.Color]::FromArgb(64, 36, 86)
                DisabledFill   = [System.Drawing.Color]::FromArgb(50, 40, 66)
                DisabledText   = [System.Drawing.Color]::FromArgb(140, 126, 162)
                DangerHover    = [System.Drawing.Color]::FromArgb(92, 32, 52)
                DangerPressed  = [System.Drawing.Color]::FromArgb(76, 26, 44)
                DangerOutline  = [System.Drawing.Color]::FromArgb(102, 44, 62)
            }
        }
        'Voltage' = @{
            Key         = 'Voltage'
            Label       = 'Voltage (dark)'
            Description = 'Inky green-black with electric lime.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(8, 12, 8)
                Sidebar     = [System.Drawing.Color]::FromArgb(11, 16, 11)
                Card        = [System.Drawing.Color]::FromArgb(16, 24, 16)
                CardAlt     = [System.Drawing.Color]::FromArgb(12, 19, 12)
                CardHover   = [System.Drawing.Color]::FromArgb(24, 35, 23)
                Border      = [System.Drawing.Color]::FromArgb(38, 56, 36)
                BorderSoft  = [System.Drawing.Color]::FromArgb(28, 42, 27)
                Text        = [System.Drawing.Color]::FromArgb(236, 248, 234)
                Muted       = [System.Drawing.Color]::FromArgb(135, 158, 131)
                Subtle      = [System.Drawing.Color]::FromArgb(99, 120, 96)
                Accent      = [System.Drawing.Color]::FromArgb(140, 255, 60)
                Accent2     = [System.Drawing.Color]::FromArgb(0, 230, 160)
                AccentSoft  = [System.Drawing.Color]::FromArgb(26, 60, 24)
                AccentHover = [System.Drawing.Color]::FromArgb(168, 255, 96)
                AccentPressed = [System.Drawing.Color]::FromArgb(108, 210, 40)
                Green       = [System.Drawing.Color]::FromArgb(108, 240, 140)
                GreenSoft   = [System.Drawing.Color]::FromArgb(23, 60, 32)
                Amber       = [System.Drawing.Color]::FromArgb(250, 200, 90)
                AmberSoft   = [System.Drawing.Color]::FromArgb(60, 48, 22)
                Red         = [System.Drawing.Color]::FromArgb(255, 105, 115)
                RedSoft     = [System.Drawing.Color]::FromArgb(66, 27, 32)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(14, 26, 6)
                NavSelected = [System.Drawing.Color]::FromArgb(28, 46, 26)
                NavHover    = [System.Drawing.Color]::FromArgb(18, 31, 17)
                Pressed     = [System.Drawing.Color]::FromArgb(23, 39, 22)
                ToggleOff   = [System.Drawing.Color]::FromArgb(48, 62, 45)
                SparkFill   = [System.Drawing.Color]::FromArgb(36, 90, 40)
                ComboSelection = [System.Drawing.Color]::FromArgb(38, 58, 36)
                DisabledFill   = [System.Drawing.Color]::FromArgb(40, 50, 39)
                DisabledText   = [System.Drawing.Color]::FromArgb(128, 145, 125)
                DangerHover    = [System.Drawing.Color]::FromArgb(88, 36, 40)
                DangerPressed  = [System.Drawing.Color]::FromArgb(74, 30, 33)
                DangerOutline  = [System.Drawing.Color]::FromArgb(96, 46, 50)
            }
        }
        'Frostbite' = @{
            Key         = 'Frostbite'
            Label       = 'Frostbite (dark)'
            Description = 'Steel blue night with an ice-cyan glow.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(7, 13, 20)
                Sidebar     = [System.Drawing.Color]::FromArgb(10, 17, 26)
                Card        = [System.Drawing.Color]::FromArgb(15, 25, 37)
                CardAlt     = [System.Drawing.Color]::FromArgb(11, 20, 30)
                CardHover   = [System.Drawing.Color]::FromArgb(22, 36, 52)
                Border      = [System.Drawing.Color]::FromArgb(36, 56, 78)
                BorderSoft  = [System.Drawing.Color]::FromArgb(27, 42, 60)
                Text        = [System.Drawing.Color]::FromArgb(230, 244, 255)
                Muted       = [System.Drawing.Color]::FromArgb(134, 158, 182)
                Subtle      = [System.Drawing.Color]::FromArgb(97, 120, 145)
                Accent      = [System.Drawing.Color]::FromArgb(56, 224, 255)
                Accent2     = [System.Drawing.Color]::FromArgb(130, 160, 255)
                AccentSoft  = [System.Drawing.Color]::FromArgb(18, 52, 70)
                AccentHover = [System.Drawing.Color]::FromArgb(92, 234, 255)
                AccentPressed = [System.Drawing.Color]::FromArgb(38, 186, 216)
                Green       = [System.Drawing.Color]::FromArgb(96, 232, 190)
                GreenSoft   = [System.Drawing.Color]::FromArgb(19, 58, 50)
                Amber       = [System.Drawing.Color]::FromArgb(252, 200, 110)
                AmberSoft   = [System.Drawing.Color]::FromArgb(60, 47, 24)
                Red         = [System.Drawing.Color]::FromArgb(255, 110, 130)
                RedSoft     = [System.Drawing.Color]::FromArgb(66, 28, 37)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(6, 22, 26)
                NavSelected = [System.Drawing.Color]::FromArgb(25, 44, 63)
                NavHover    = [System.Drawing.Color]::FromArgb(16, 30, 45)
                Pressed     = [System.Drawing.Color]::FromArgb(20, 36, 52)
                ToggleOff   = [System.Drawing.Color]::FromArgb(46, 64, 84)
                SparkFill   = [System.Drawing.Color]::FromArgb(22, 70, 96)
                ComboSelection = [System.Drawing.Color]::FromArgb(35, 57, 80)
                DisabledFill   = [System.Drawing.Color]::FromArgb(40, 53, 67)
                DisabledText   = [System.Drawing.Color]::FromArgb(126, 144, 164)
                DangerHover    = [System.Drawing.Color]::FromArgb(88, 36, 48)
                DangerPressed  = [System.Drawing.Color]::FromArgb(73, 30, 40)
                DangerOutline  = [System.Drawing.Color]::FromArgb(96, 46, 58)
            }
        }
        'Magma' = @{
            Key         = 'Magma'
            Label       = 'Magma (dark)'
            Description = 'Charcoal ash with lava orange and gold.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(18, 11, 10)
                Sidebar     = [System.Drawing.Color]::FromArgb(24, 14, 13)
                Card        = [System.Drawing.Color]::FromArgb(34, 20, 18)
                CardAlt     = [System.Drawing.Color]::FromArgb(28, 17, 15)
                CardHover   = [System.Drawing.Color]::FromArgb(50, 29, 26)
                Border      = [System.Drawing.Color]::FromArgb(72, 42, 37)
                BorderSoft  = [System.Drawing.Color]::FromArgb(54, 32, 28)
                Text        = [System.Drawing.Color]::FromArgb(255, 240, 235)
                Muted       = [System.Drawing.Color]::FromArgb(186, 148, 140)
                Subtle      = [System.Drawing.Color]::FromArgb(138, 107, 100)
                Accent      = [System.Drawing.Color]::FromArgb(255, 82, 40)
                Accent2     = [System.Drawing.Color]::FromArgb(255, 168, 42)
                AccentSoft  = [System.Drawing.Color]::FromArgb(74, 30, 22)
                AccentHover = [System.Drawing.Color]::FromArgb(255, 110, 70)
                AccentPressed = [System.Drawing.Color]::FromArgb(214, 62, 26)
                Green       = [System.Drawing.Color]::FromArgb(110, 225, 160)
                GreenSoft   = [System.Drawing.Color]::FromArgb(25, 60, 42)
                Amber       = [System.Drawing.Color]::FromArgb(255, 200, 96)
                AmberSoft   = [System.Drawing.Color]::FromArgb(68, 50, 22)
                Red         = [System.Drawing.Color]::FromArgb(255, 100, 110)
                RedSoft     = [System.Drawing.Color]::FromArgb(72, 26, 32)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(26, 8, 4)
                NavSelected = [System.Drawing.Color]::FromArgb(58, 30, 26)
                NavHover    = [System.Drawing.Color]::FromArgb(36, 21, 18)
                Pressed     = [System.Drawing.Color]::FromArgb(45, 25, 22)
                ToggleOff   = [System.Drawing.Color]::FromArgb(78, 54, 48)
                SparkFill   = [System.Drawing.Color]::FromArgb(104, 42, 28)
                ComboSelection = [System.Drawing.Color]::FromArgb(68, 38, 32)
                DisabledFill   = [System.Drawing.Color]::FromArgb(58, 45, 42)
                DisabledText   = [System.Drawing.Color]::FromArgb(158, 133, 127)
                DangerHover    = [System.Drawing.Color]::FromArgb(94, 36, 42)
                DangerPressed  = [System.Drawing.Color]::FromArgb(78, 30, 35)
                DangerOutline  = [System.Drawing.Color]::FromArgb(104, 46, 52)
            }
        }
        'Aqua' = @{
            Key         = 'Aqua'
            Label       = 'Aqua (dark)'
            Description = 'Deep ocean teal with aqua and violet.'
            Dark        = $true
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(6, 16, 18)
                Sidebar     = [System.Drawing.Color]::FromArgb(9, 21, 23)
                Card        = [System.Drawing.Color]::FromArgb(13, 30, 33)
                CardAlt     = [System.Drawing.Color]::FromArgb(10, 24, 26)
                CardHover   = [System.Drawing.Color]::FromArgb(20, 43, 47)
                Border      = [System.Drawing.Color]::FromArgb(31, 64, 68)
                BorderSoft  = [System.Drawing.Color]::FromArgb(23, 48, 52)
                Text        = [System.Drawing.Color]::FromArgb(230, 248, 250)
                Muted       = [System.Drawing.Color]::FromArgb(130, 165, 170)
                Subtle      = [System.Drawing.Color]::FromArgb(94, 126, 131)
                Accent      = [System.Drawing.Color]::FromArgb(34, 225, 220)
                Accent2     = [System.Drawing.Color]::FromArgb(157, 110, 255)
                AccentSoft  = [System.Drawing.Color]::FromArgb(16, 60, 62)
                AccentHover = [System.Drawing.Color]::FromArgb(74, 236, 229)
                AccentPressed = [System.Drawing.Color]::FromArgb(24, 184, 180)
                Green       = [System.Drawing.Color]::FromArgb(98, 232, 168)
                GreenSoft   = [System.Drawing.Color]::FromArgb(18, 60, 44)
                Amber       = [System.Drawing.Color]::FromArgb(252, 202, 104)
                AmberSoft   = [System.Drawing.Color]::FromArgb(60, 48, 24)
                Red         = [System.Drawing.Color]::FromArgb(255, 106, 124)
                RedSoft     = [System.Drawing.Color]::FromArgb(66, 27, 35)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(3, 22, 22)
                NavSelected = [System.Drawing.Color]::FromArgb(21, 50, 53)
                NavHover    = [System.Drawing.Color]::FromArgb(14, 35, 38)
                Pressed     = [System.Drawing.Color]::FromArgb(17, 42, 45)
                ToggleOff   = [System.Drawing.Color]::FromArgb(44, 68, 70)
                SparkFill   = [System.Drawing.Color]::FromArgb(18, 82, 86)
                ComboSelection = [System.Drawing.Color]::FromArgb(30, 62, 66)
                DisabledFill   = [System.Drawing.Color]::FromArgb(38, 55, 57)
                DisabledText   = [System.Drawing.Color]::FromArgb(122, 148, 151)
                DangerHover    = [System.Drawing.Color]::FromArgb(88, 34, 44)
                DangerPressed  = [System.Drawing.Color]::FromArgb(73, 28, 37)
                DangerOutline  = [System.Drawing.Color]::FromArgb(96, 44, 54)
            }
        }
        'Solar' = @{
            Key         = 'Solar'
            Label       = 'Solar (light)'
            Description = 'Warm cream with coral and golden light.'
            Dark        = $false
            Palette     = @{
                Bg          = [System.Drawing.Color]::FromArgb(253, 247, 240)
                Sidebar     = [System.Drawing.Color]::FromArgb(249, 240, 231)
                Card        = [System.Drawing.Color]::FromArgb(255, 255, 255)
                CardAlt     = [System.Drawing.Color]::FromArgb(253, 249, 243)
                CardHover   = [System.Drawing.Color]::FromArgb(249, 236, 226)
                Border      = [System.Drawing.Color]::FromArgb(236, 211, 195)
                BorderSoft  = [System.Drawing.Color]::FromArgb(244, 226, 213)
                Text        = [System.Drawing.Color]::FromArgb(53, 35, 28)
                Muted       = [System.Drawing.Color]::FromArgb(126, 100, 88)
                Subtle      = [System.Drawing.Color]::FromArgb(160, 134, 121)
                Accent      = [System.Drawing.Color]::FromArgb(240, 90, 60)
                Accent2     = [System.Drawing.Color]::FromArgb(245, 150, 50)
                AccentSoft  = [System.Drawing.Color]::FromArgb(253, 230, 222)
                AccentHover = [System.Drawing.Color]::FromArgb(246, 112, 84)
                AccentPressed = [System.Drawing.Color]::FromArgb(204, 70, 44)
                Green       = [System.Drawing.Color]::FromArgb(26, 132, 82)
                GreenSoft   = [System.Drawing.Color]::FromArgb(223, 244, 233)
                Amber       = [System.Drawing.Color]::FromArgb(170, 112, 14)
                AmberSoft   = [System.Drawing.Color]::FromArgb(252, 240, 216)
                Red         = [System.Drawing.Color]::FromArgb(200, 52, 62)
                RedSoft     = [System.Drawing.Color]::FromArgb(252, 227, 228)
                White       = [System.Drawing.Color]::White
                AccentText  = [System.Drawing.Color]::FromArgb(24, 9, 6)
                NavSelected = [System.Drawing.Color]::FromArgb(248, 230, 218)
                NavHover    = [System.Drawing.Color]::FromArgb(252, 240, 233)
                Pressed     = [System.Drawing.Color]::FromArgb(244, 222, 208)
                ToggleOff   = [System.Drawing.Color]::FromArgb(226, 205, 190)
                SparkFill   = [System.Drawing.Color]::FromArgb(250, 216, 198)
                ComboSelection = [System.Drawing.Color]::FromArgb(248, 230, 218)
                DisabledFill   = [System.Drawing.Color]::FromArgb(242, 235, 228)
                DisabledText   = [System.Drawing.Color]::FromArgb(127, 106, 93)
                DangerHover    = [System.Drawing.Color]::FromArgb(249, 219, 216)
                DangerPressed  = [System.Drawing.Color]::FromArgb(243, 203, 199)
                DangerOutline  = [System.Drawing.Color]::FromArgb(229, 172, 165)
            }
        }
    }
    return $script:StudioThemeCatalog
}

function Resolve-StudioThemeKey {
    param([string]$Theme = 'Aurora')
    $catalog = Get-StudioThemeCatalog
    $aliases = @{
        'dark' = 'Aurora'
        'light' = 'Daylight'
    }
    $value = ([string]$Theme).Trim()
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        foreach ($key in $catalog.Keys) {
            if ([string]::Equals($value, [string]$key, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$key
            }
            $entry = $catalog[$key]
            if ([string]::Equals($value, [string]$entry.Label, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$key
            }
        }
        if ($aliases.ContainsKey($value.ToLowerInvariant())) {
            return [string]$aliases[$value.ToLowerInvariant()]
        }
    }
    return 'Aurora'
}

function Get-StudioThemeList {
    $catalog = Get-StudioThemeCatalog
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($key in $catalog.Keys) {
        $entry = $catalog[$key]
        $list.Add([pscustomobject]@{
            Key         = [string]$entry.Key
            Label       = [string]$entry.Label
            Description = [string]$entry.Description
            Dark        = [bool]$entry.Dark
        })
    }
    return $list.ToArray()
}

function Get-StudioThemeLabel {
    param($Entry)
    if ($null -eq $Entry) { return '' }
    return (T ('Theme' + [string]$Entry.Key + 'Label') ([string]$Entry.Label))
}

function Get-StudioThemeDescription {
    param($Entry)
    if ($null -eq $Entry) { return '' }
    return (T ('Theme' + [string]$Entry.Key + 'Desc') ([string]$Entry.Description))
}

function Get-StudioPalette {
    param([string]$Theme = 'Aurora')
    $key = Resolve-StudioThemeKey -Theme $Theme
    $entry = (Get-StudioThemeCatalog)[$key]
    return $entry.Palette.Clone()
}

function Update-StudioThemeControl {
    param($Control, [hashtable]$ColorMap)
    if ($null -eq $Control) { return }
    $type = $Control.GetType()
    while ($null -ne $type) {
        foreach ($property in $type.GetProperties([System.Reflection.BindingFlags]'Instance,Public')) {
            if ($property.PropertyType -ne [System.Drawing.Color] -or -not $property.CanRead -or -not $property.CanWrite) { continue }
            if ($property.GetIndexParameters().Length -gt 0) { continue }
            try {
                $current = [System.Drawing.Color]$property.GetValue($Control, $null)
                if ($current.IsEmpty) { continue }
                $argb = [int]$current.ToArgb()
                if ($ColorMap.ContainsKey($argb)) {
                    $next = [System.Drawing.Color]$ColorMap[$argb]
                    if ($next -ne $current) { $property.SetValue($Control, $next, $null) }
                }
            } catch { }
        }
        $type = $type.BaseType
    }
    foreach ($child in @($Control.Controls)) {
        Update-StudioThemeControl -Control $child -ColorMap $ColorMap
    }
}

function Apply-StudioTheme {
    param([string]$Theme, $Root)
    $key = Resolve-StudioThemeKey -Theme $Theme
    if ($key -eq $script:ThemeKey) { return $key }
    $oldPalette = $script:P
    $newPalette = Get-StudioPalette -Theme $key
    $map = @{}
    foreach ($name in @($oldPalette.Keys)) {
        if (-not $newPalette.ContainsKey($name)) { continue }
        $oldColor = [System.Drawing.Color]$oldPalette[$name]
        if ($oldColor.IsEmpty) { continue }
        $argb = [int]$oldColor.ToArgb()
        if (-not $map.ContainsKey($argb)) { $map[$argb] = [System.Drawing.Color]$newPalette[$name] }
    }
    $script:ThemeKey = $key
    $script:P = $newPalette
    if ($null -ne $Root) {
        Update-StudioThemeControl -Control $Root -ColorMap $map
        try {
            $Root.Invalidate($true)
            $Root.Update()
        } catch { }
    }
    return $key
}
