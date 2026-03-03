import re

def main():
    with open("modules/Properties.lua", "r") as f:
        props = f.read()

    # Find the block where piTextSlider is configured.
    # The review said piTextSliderMinusBtn and piTextSliderPlusBtn are INSIDE OnValueChanged.
    # Let's see the context.
    start_idx = props.find('piTextSlider:SetScript("OnValueChanged"')
    if start_idx != -1:
        end_idx = props.find('tinsert(panel.controls, piTextSlider)', start_idx)
        block = props[start_idx:end_idx]

        # Are there any buttons inside this block?
        match_btns = re.search(r'(-- Minus Button for piTextSlider.*?tinsert\(panel\.controls, piTextSliderPlusBtn\))', block, re.DOTALL)
        if match_btns:
            buttons_text = match_btns.group(1)
            # Remove buttons from inside the function
            new_block = block.replace(buttons_text, "")
            props = props.replace(block, new_block)

            # Re-insert the buttons after the tinsert
            tinsert_str = 'tinsert(panel.controls, piTextSlider)'
            insert_pos = props.find(tinsert_str, start_idx) + len(tinsert_str)
            props = props[:insert_pos] + '\n' + buttons_text + props[insert_pos:]

            with open("modules/Properties.lua", "w") as f:
                f.write(props)
            print("Moved piTextSlider buttons out of OnValueChanged")
        else:
            print("Could not find buttons inside OnValueChanged for piTextSlider")

if __name__ == "__main__":
    main()
